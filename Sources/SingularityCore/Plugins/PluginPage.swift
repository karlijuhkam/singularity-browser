import Foundation

// Pure decisions behind plugin page scripts (the app's PluginScripts / PluginPageBridge use them).

// MARK: - Fill guard

/// Decides whether a plugin's fill may reach a frame. A fill is the background's reply
/// `{fill: {forHost, username, password}}` to a page script's `singularity.send`.
public enum FillGuard {
    /// The frame's host must be the host the login was saved for, or a subdomain of it.
    /// ("www.github.com" may get a github.com login; "github.com" may not get a www.github.com
    /// login, and "evilgithub.com" never gets one.)
    public static func allows(frameHost: String, forHost: String) -> Bool {
        HostMatch.isSameOrSubdomain(frameHost, of: forHost)
    }

    public enum Decision: Equatable, Sendable {
        /// The reply has no top-level "fill": deliver it as it is.
        case notAFill
        /// A fill that passed every check: deliver it.
        case allowed
        /// A fill that must not be delivered.
        case blocked(Reason)
    }

    public enum Reason: Equatable, Sendable {
        /// "fill" isn't `{forHost: string, username?: string, password?: string}`.
        case malformed
        /// (a) The frame's host doesn't match `forHost`.
        case hostMismatch
        /// (b) The frame isn't on a site in the plugin's `fillForms`.
        case siteNotPermitted
        /// (c) The request didn't come from a real click on the plugin's button or menu.
        case notFromClick
    }

    /// All three checks, in this order: shape, (a) host, (b) fillForms, (c) real click.
    /// `frameHost` is the frame's security origin host and `frameURL` comes from `PluginFrame.url`;
    /// both are WebKit's word for where the request came from, never the page's.
    public static func check(reply: JSONValue, frameHost: String, frameURL: URL, fillForms: [SitePattern],
                             clickOriginated: Bool) -> Decision {
        check(reply: reply, frameHost: frameHost, frameURL: frameURL, clickOriginated: clickOriginated) { url in
            fillForms.contains { $0.matches(url) }
        }
    }

    /// The same, with (b) answered by `access.fills` (manifest and approval must both allow it).
    public static func check(reply: JSONValue, frameHost: String, frameURL: URL, access: PluginPageAccess,
                             clickOriginated: Bool) -> Decision {
        check(reply: reply, frameHost: frameHost, frameURL: frameURL, clickOriginated: clickOriginated, fillsSite: access.fills)
    }

    private static func check(reply: JSONValue, frameHost: String, frameURL: URL, clickOriginated: Bool,
                              fillsSite: (URL) -> Bool) -> Decision {
        guard case .object(let object) = reply, let fill = object["fill"] else { return .notAFill }
        guard case .object(let fields) = fill, case .string(let forHost)? = fields["forHost"] else {
            return .blocked(.malformed)
        }
        for key in ["username", "password"] {
            if let value = fields[key], case .string = value { continue }
            if fields[key] != nil { return .blocked(.malformed) }
        }
        guard allows(frameHost: frameHost, forHost: forHost) else { return .blocked(.hostMismatch) }
        guard fillsSite(frameURL) else { return .blocked(.siteNotPermitted) }
        guard clickOriginated else { return .blocked(.notFromClick) }
        return .allowed
    }
}

// MARK: - Which plugins a Space gets

public enum PluginSelection {
    /// The ids (sorted) of the plugins whose page scripts belong in a Space's web views: exactly
    /// the plugins the manager would run there. That means approved as they are now (`.changed`,
    /// `.permissionsWidened` and `.new` are out), switched on for this Space, and nothing they
    /// need is missing (launch decision `.launch`, or `.nothingToRun` for a plugin without a
    /// background program). A plugin missing from `statuses` or `decisions` is left out.
    public static func forSpace(_ spaceID: UUID, approvals: [String: PluginApproval],
                                statuses: [String: PluginStatus],
                                decisions: [String: PluginLaunch.Decision]) -> [String] {
        approvals.compactMap { id, approval -> String? in
            guard statuses[id] == .approved, approval.enabledSpaces.contains(spaceID) else { return nil }
            switch decisions[id] {
            case .launch?, .nothingToRun?: return id
            default: return nil
            }
        }
        .sorted()
    }
}

// MARK: - Where a plugin may act

/// The sites a plugin's page script may run on and fill. Both the manifest as it is now and the
/// approved permissions must allow it (they normally agree: a manifest that asks for more isn't
/// `.approved`).
public struct PluginPageAccess: Sendable {
    public let pageSites: [SitePattern]
    public let pageAdditions: [SitePattern]
    public let approvedPageAdditions: [SitePattern]
    public let fillForms: [SitePattern]
    public let approvedFillForms: [SitePattern]

    public init(manifest: PluginManifest, approved: PluginManifest.Permissions) {
        // The manifest's patterns were validated when it was loaded; an invalid one would just be skipped.
        func patterns(_ texts: [String]) -> [SitePattern] { texts.compactMap { try? SitePattern($0) } }
        pageSites = patterns(manifest.page?.sites ?? [])
        pageAdditions = patterns(manifest.permissions.pageAdditions)
        approvedPageAdditions = patterns(approved.pageAdditions)
        fillForms = patterns(manifest.permissions.fillForms)
        approvedFillForms = patterns(approved.fillForms)
    }

    /// The page script runs on `url` (a page or frame URL): it is in `page.sites` and in
    /// `pageAdditions`.
    public func runsOn(_ url: URL) -> Bool {
        Self.any(pageSites, url) && Self.any(pageAdditions, url) && Self.any(approvedPageAdditions, url)
    }

    /// Fills may be delivered to a frame at `url`.
    public func fills(_ url: URL) -> Bool {
        Self.any(fillForms, url) && Self.any(approvedFillForms, url)
    }

    private static func any(_ patterns: [SitePattern], _ url: URL) -> Bool {
        patterns.contains { $0.matches(url) }
    }
}

/// The URL of the frame a page message came from, built from what WebKit reports.
public enum PluginFrame {
    /// `originProtocol`/`originHost`/`originPort` are the frame's security origin (port 0 =
    /// the scheme's default); `requestURL` is the frame's current request. The origin is what the
    /// site check relies on: the request URL only adds its path and query, and only when it is on
    /// the same origin (an about:blank or srcdoc frame inherits its parent's origin, so its own
    /// URL says nothing). Then the path is "/". Nil for opaque origins (sandboxed frames, data:
    /// URLs) and anything that isn't http(s): no plugin acts there.
    public static func url(originProtocol: String, originHost: String, originPort: Int, requestURL: URL?) -> URL? {
        let scheme = originProtocol.lowercased()
        guard scheme == "http" || scheme == "https", !originHost.isEmpty else { return nil }
        let defaultPort = scheme == "https" ? 443 : 80
        let port = originPort == 0 ? defaultPort : originPort

        var components = URLComponents()
        components.scheme = scheme
        components.host = originHost
        if port != defaultPort { components.port = port }
        components.path = "/"
        if let request = requestURL,
           request.scheme?.lowercased() == scheme,
           request.host()?.lowercased() == originHost.lowercased(),
           (request.port ?? defaultPort) == port {
            let path = request.path(percentEncoded: true)
            components.percentEncodedPath = path.isEmpty ? "/" : path
            components.percentEncodedQuery = request.query(percentEncoded: true)
        }
        return components.url
    }
}

// MARK: - Messages from page scripts

/// A message from a plugin's page script (the prelude in `PluginPrelude.swift` sends these).
/// Everything in it is untrusted: the plugin's page code shares its world with the prelude.
public enum PluginPageRequest: Equatable, Sendable {
    /// A real click on the plugin's button or menu: asks for a click token (see `ClickTokens`).
    /// `secret` proves the message came from the prelude, not from the plugin's own code.
    case click(secret: String)
    /// `singularity.send(payload)`; `token` is a click token when the send follows a real click.
    case send(payload: JSONValue, token: String?)

    /// Payloads larger than this (as JSON text, in bytes) are refused.
    public static let maxPayloadBytes = 256 * 1024
    /// Nesting deeper than this is refused (decoding is recursive).
    static let maxDepth = 64

    public enum ParseError: Error, Equatable, Sendable { case malformed, tooLarge }

    /// `body` is what WebKit made of the object the page posted: `{type: "click", secret}` or
    /// `{type: "send", json, token?}` (the payload travels as JSON text, so its size is known
    /// before it is decoded).
    public static func parse(_ body: Any) -> Result<PluginPageRequest, ParseError> {
        guard let dict = body as? [String: Any], let type = dict["type"] as? String else { return .failure(.malformed) }
        switch type {
        case "click":
            guard let secret = dict["secret"] as? String else { return .failure(.malformed) }
            return .success(.click(secret: secret))
        case "send":
            guard let json = dict["json"] as? String else { return .failure(.malformed) }
            guard json.utf8.count <= maxPayloadBytes else { return .failure(.tooLarge) }
            guard nestingDepth(json) <= maxDepth,
                  let payload = try? JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)) else {
                return .failure(.malformed)
            }
            return .success(.send(payload: payload, token: dict["token"] as? String))
        default:
            return .failure(.malformed)
        }
    }

    /// The deepest `[`/`{` nesting in JSON text (outside strings).
    static func nestingDepth(_ json: String) -> Int {
        var depth = 0, deepest = 0, inString = false, escaped = false
        for byte in json.utf8 {
            if inString {
                if escaped { escaped = false } else if byte == 0x5C { escaped = true } else if byte == 0x22 { inString = false }
                continue
            }
            switch byte {
            case 0x22: inString = true
            case 0x5B, 0x7B: depth += 1; deepest = max(deepest, depth)
            case 0x5D, 0x7D: depth -= 1
            default: break
            }
        }
        return deepest
    }

    /// A random 32-byte secret, as 64 hex digits.
    public static func makeSecret() -> String { randomHex(bytes: 32) }

    /// Compares in time independent of where the strings differ. Empty secrets never match.
    public static func secretsMatch(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard !x.isEmpty, x.count == y.count else { return false }
        var difference: UInt8 = 0
        for i in x.indices { difference |= x[i] ^ y[i] }
        return difference == 0
    }
}

/// Lowercase hex of `bytes` random bytes (SystemRandomNumberGenerator is cryptographically secure).
func randomHex(bytes: Int) -> String {
    var generator = SystemRandomNumberGenerator()
    return (0..<bytes).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max, using: &generator)) }.joined()
}

/// One-time tokens that mark a `send` as following a real click.
///
/// The scheme: the prelude (the app's code that runs before the plugin's code in its world)
/// listens for clicks on the plugin's buttons and menu items. On a real click (`isTrusted`) it
/// asks Singularity for a token, proving with a secret only the prelude knows that the request is
/// its own. Singularity issues a random token, scoped to the tab and frame host, valid for 2 s and
/// one use. The plugin's next `send` within that time carries it; only such a send may get a fill.
public struct ClickTokens: Sendable {
    public static let lifetime: TimeInterval = 2
    public static let maxOutstanding = 16

    /// token -> where it may be used, when it was issued, and an issue counter (to find the oldest
    /// even when several were issued at the same instant).
    private var tokens: [String: (scope: String, issued: Date, order: Int)] = [:]
    private var issued = 0

    public init() {}

    public var count: Int { tokens.count }

    /// A new token for `scope` (e.g. "<tab id>|<frame host>"). Expired tokens are forgotten; at
    /// most `maxOutstanding` are kept (the oldest goes first).
    public mutating func issue(scope: String, now: Date) -> String {
        tokens = tokens.filter { now.timeIntervalSince($0.value.issued) <= Self.lifetime }
        while tokens.count >= Self.maxOutstanding, let oldest = tokens.min(by: { $0.value.order < $1.value.order }) {
            tokens[oldest.key] = nil
        }
        let token = randomHex(bytes: 16)
        issued += 1
        tokens[token] = (scope, now, issued)
        return token
    }

    /// True once for a token issued for this scope less than `lifetime` ago; the token is used up.
    /// A token offered from another scope stays unused.
    public mutating func consume(_ token: String, scope: String, now: Date) -> Bool {
        guard let entry = tokens[token], entry.scope == scope else { return false }
        tokens[token] = nil
        return now.timeIntervalSince(entry.issued) <= Self.lifetime
    }
}

// MARK: - Replies to WebKit

extension JSONValue {
    /// The value as Foundation objects (NSDictionary, NSArray, NSString, NSNumber, NSNull), which
    /// WebKit turns into JavaScript values when it answers a page's `postMessage`.
    public var foundationObject: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let b): return NSNumber(value: b)
        case .number(let n): return NSNumber(value: n)
        case .string(let s): return s
        case .array(let a): return a.map(\.foundationObject)
        case .object(let o): return o.mapValues(\.foundationObject)
        }
    }
}
