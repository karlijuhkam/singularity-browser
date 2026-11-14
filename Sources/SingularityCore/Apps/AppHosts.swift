import Foundation

/// Why an app's outside request was not made. The message goes to the Worker as the error of
/// its `fetch()`, so it is written for the person (or agent) reading the Worker's log.
public struct AppFetchRefusal: Error, Equatable, Sendable {
    public var message: String
    public init(_ message: String) { self.message = message }
}

/// Which outside addresses an app's Worker may ask for at all, before the owner's list of
/// allowed hosts is looked at.
public enum AppHostRules {
    /// Hosts reached over plain http: only this Mac (a local dev server).
    static let loopbackHosts: Set<String> = ["localhost", "127.0.0.1", "::1"]

    /// The host an outside request is for (lowercase, no port, no brackets), or why it is refused:
    /// - https to any host;
    /// - http only to this Mac;
    /// - no user name or password in the address (they would end up in logs).
    public static func target(of url: String) -> Result<String, AppFetchRefusal> {
        guard let components = URLComponents(string: url), let scheme = components.scheme?.lowercased(),
              let rawHost = components.host, !rawHost.isEmpty else {
            return .failure(AppFetchRefusal("Not an address an app can fetch: \(url.prefix(200))"))
        }
        let host = normalise(rawHost)
        guard components.user == nil, components.password == nil else {
            return .failure(AppFetchRefusal("An address with a user name or password in it is not fetched (\(host))."))
        }
        // The same rule as for a host the owner types: what can't be listed can't be allowed,
        // so asking about it would only ever end in "not allowed".
        guard isValidHost(host) else {
            return .failure(AppFetchRefusal("Not a host an app can fetch: \(host.prefix(100))"))
        }
        switch scheme {
        case "https":
            return .success(host)
        case "http":
            guard loopbackHosts.contains(host) else {
                return .failure(AppFetchRefusal("Only https is fetched (http only on this Mac): \(host)"))
            }
            return .success(host)
        default:
            return .failure(AppFetchRefusal("Only https is fetched, not \(scheme):"))
        }
    }

    /// Whether `text` is a host name the panel may add: what `target(of:)` would return.
    public static func isValidHost(_ text: String) -> Bool {
        guard !text.isEmpty, text.count <= 253, text == text.lowercased() else { return false }
        // A host only: no scheme, path, port, spaces or wildcards.
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.-_:")
        guard text.unicodeScalars.allSatisfy(allowed.contains) else { return false }
        if text.contains(":") { return text == "::1" }   // the only IPv6 host we take by hand
        return !text.hasPrefix(".") && !text.hasSuffix(".") && !text.hasPrefix("-") && !text.contains("..")
    }

    /// Lowercase, without the brackets of an IPv6 literal or a trailing dot.
    static func normalise(_ host: String) -> String {
        var host = host.lowercased()
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if host.hasSuffix("."), host.count > 1 { host.removeLast() }
        return host
    }
}

/// One running Worker's view of the hosts it may reach, and of the questions the owner is being
/// asked right now. Pure state: the caller keeps it on one actor.
///
/// A host the owner said no to (or did not answer in time) is refused without asking again until
/// the Worker next starts (a new gate): a page that polls must not fill the inbox.
public struct AppHostGate: Sendable {
    public enum Decision: Equatable, Sendable {
        /// The owner allowed this host.
        case allow
        /// Denied earlier in this run: fail without asking.
        case refuse
        /// Ask the owner. The host is now waiting; call `answered` with the result.
        case ask
        /// A question for this host is already waiting: wait for the same answer.
        case joinWaiting
    }

    private var allowed: Set<String>
    private var denied: Set<String> = []
    private var waiting: Set<String> = []

    public init(allowed: Set<String>) {
        self.allowed = allowed
    }

    public mutating func decide(_ host: String) -> Decision {
        if allowed.contains(host) { return .allow }
        if denied.contains(host) { return .refuse }
        if waiting.contains(host) { return .joinWaiting }
        waiting.insert(host)
        return .ask
    }

    /// The owner answered (or the question timed out: `allowed` false).
    public mutating func answered(_ host: String, allowed isAllowed: Bool) {
        waiting.remove(host)
        if isAllowed {
            allowed.insert(host)
            denied.remove(host)
        } else if !allowed.contains(host) {
            denied.insert(host)
        }
    }

    /// The owner changed the list in the app's panel. A host added there is no longer denied.
    /// The question for `host` could not be asked at all (too many already wait in the inbox):
    /// the host is neither allowed nor denied, and the next request asks again.
    public mutating func notAsked(_ host: String) {
        waiting.remove(host)
    }

    public mutating func setAllowed(_ hosts: Set<String>) {
        allowed = hosts
        denied.subtract(hosts)
    }

    /// Hosts refused in this run, for the panel (each with an Allow button).
    public var deniedThisRun: [String] { denied.sorted() }
}
