import Foundation
import SingularityCore
import WebKit

/// The native end of one plugin's page API in one content controller: the message handler
/// "singularityPlugin", registered only in the plugin's own content world (see `PluginScripts`).
///
/// How it works: the prelude calls `webkit.messageHandlers.singularityPlugin.postMessage(...)`;
/// WebKit delivers the message here together with `frameInfo`, which says which frame (and security
/// origin) it came from. A page can't fake `frameInfo`. Whatever we return becomes the value the
/// JavaScript Promise resolves with; an error string rejects it.
///
/// Everything in a message is untrusted (the plugin's page code shares its world with the
/// prelude), so every message is checked here:
/// - its size and shape (`PluginPageRequest.parse`: 256 KB at most);
/// - the frame's URL, built from the frame's security origin (`PluginFrame.url`), must be one of the
///   plugin's `page.sites` and in `pageAdditions` (`PluginPageAccess.runsOn`);
/// - a reply that is a fill is only delivered after `FillGuard.check`: the frame's host matches the
///   login's host, the frame is on a `fillForms` site, and the request followed a real click (it
///   carried a click token this bridge issued). Otherwise the page gets `{error: "fill blocked"}`
///   and the plugin's log says "blocked fill for <frame host>", never the credentials.
/// What the bridge needs from the plugin manager (a protocol so it can be tried out on its own).
@MainActor
protocol PluginPageBackend: AnyObject {
    func send(pluginID: String, tabID: UUID, space: UUID, frameHost: String, payload: JSONValue) async -> JSONValue?
    func log(_ id: String, _ level: String, _ message: String)
}

extension PluginManager: PluginPageBackend {}

@MainActor
final class PluginPageBridge: NSObject, WKScriptMessageHandlerWithReply {
    private let pluginID: String
    private let spaceID: UUID
    private let access: PluginPageAccess
    /// Known only to this bridge and to the prelude it was built with (`PluginScripts.rebuild`).
    private let secret: String
    private weak var manager: PluginPageBackend?
    private let tabID: (WKWebView) -> UUID?
    private var tokens = ClickTokens()

    init(pluginID: String, spaceID: UUID, access: PluginPageAccess, secret: String, manager: PluginPageBackend?,
         tabID: @escaping (WKWebView) -> UUID?) {
        self.pluginID = pluginID
        self.spaceID = spaceID
        self.access = access
        self.secret = secret
        self.manager = manager
        self.tabID = tabID
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) async -> (Any?, String?) {
        let request: PluginPageRequest
        switch PluginPageRequest.parse(message.body) {
        case .success(let value): request = value
        case .failure(.tooLarge): return (nil, "the message is larger than 256 KB")
        case .failure(.malformed): return (nil, "malformed message")
        }

        // Where the message really came from, in WebKit's words.
        let frame = message.frameInfo
        let origin = frame.securityOrigin
        guard let frameURL = PluginFrame.url(originProtocol: origin.protocol, originHost: origin.host,
                                             originPort: origin.port, requestURL: frame.request.url),
              access.runsOn(frameURL) else {
            return (nil, "this plugin can't act on this page")
        }
        guard let webView = message.webView, let tabID = tabID(webView) else {
            return (nil, "this page isn't in a Singularity tab")
        }
        // Click tokens are only good in the tab and frame host they were issued for.
        let scope = "\(tabID.uuidString)|\(origin.host.lowercased())"

        switch request {
        case .click(let offered):
            guard PluginPageRequest.secretsMatch(offered, secret) else { return (nil, "not allowed") }
            return (tokens.issue(scope: scope, now: Date()), nil)

        case let .send(payload, token):
            // Decided now, when the request arrives (a reply may take a while: Touch ID).
            let clicked = token.map { tokens.consume($0, scope: scope, now: Date()) } ?? false
            guard let manager else { return (nil, "Singularity is shutting down") }
            guard let reply = await manager.send(pluginID: pluginID, tabID: tabID, space: spaceID,
                                                 frameHost: origin.host, payload: payload) else {
                return (nil, "the plugin isn't running or didn't answer")
            }
            switch FillGuard.check(reply: reply, frameHost: origin.host, frameURL: frameURL, access: access,
                                   clickOriginated: clicked) {
            case .notAFill, .allowed:
                return (reply.foundationObject, nil)
            case .blocked(let reason):
                // The host and the reason only: never the credentials, not even their length.
                self.manager?.log(pluginID, "warn", "blocked fill for \(origin.host) (\(Self.describe(reason)))")
                return (["error": "fill blocked"], nil)
            }
        }
    }

    private static func describe(_ reason: FillGuard.Reason) -> String {
        switch reason {
        case .malformed: return "the reply's fill isn't {forHost, username, password}"
        case .hostMismatch: return "the login is for another site"
        case .siteNotPermitted: return "this site isn't in the plugin's fillForms"
        case .notFromClick: return "not right after a click on the plugin's button or menu"
        }
    }
}
