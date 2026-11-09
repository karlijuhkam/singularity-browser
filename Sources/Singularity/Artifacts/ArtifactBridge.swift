import Foundation
import SingularityCore
import WebKit

/// The `window.singularity` object that artifact pages (and only artifact pages) get.
///
/// How it works: a `WKUserScript` defines `window.singularity` at page start. Its functions call
/// `webkit.messageHandlers.singularity.postMessage(...)`, which WebKit delivers to this Swift
/// object; whatever we return becomes the resolved value of the Promise in JavaScript.
/// Nothing reaches the terminal without passing through `AppState`, which asks the user first.
@MainActor
final class ArtifactBridge: NSObject, WKScriptMessageHandlerWithReply {
    static let handlerName = "singularity"

    private weak var state: AppState?
    private let spaceID: UUID
    private let port: UInt16

    init(state: AppState?, spaceID: UUID, port: UInt16) {
        self.state = state
        self.spaceID = spaceID
        self.port = port
    }

    /// Adds the script and the message handler to a web view configuration.
    func install(in configuration: WKWebViewConfiguration) {
        let script = WKUserScript(
            source: Self.scriptSource(port: port),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
        configuration.userContentController.addUserScript(script)
        configuration.userContentController.addScriptMessageHandler(self, contentWorld: .page, name: Self.handlerName)
    }

    /// The JavaScript side. It only defines `window.singularity` on this Space's artifact origin,
    /// so a page you navigate to from an artifact tab does not get it.
    static func scriptSource(port: UInt16) -> String {
        """
        (() => {
          if (location.origin !== "http://127.0.0.1:\(port)") return;
          const send = (message) => window.webkit.messageHandlers.\(handlerName).postMessage(message);
          const api = {
            /** Paste text into this Space's active terminal and press Return (asks the user first). */
            prompt: (text) => send({ type: "prompt", text: String(text) }),
            /** Open a URL in a new web tab in this Space. */
            open: (url) => send({ type: "open", url: new URL(String(url), location.href).href }),
          };
          Object.defineProperty(window, "singularity", { value: Object.freeze(api), writable: false, configurable: false });
        })();
        """
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) async -> (Any?, String?) {
        // A page that isn't on this Space's artifact server could still call
        // webkit.messageHandlers.singularity directly (e.g. after navigating away), so check where
        // the message really came from. WebKit fills in `securityOrigin`; the page can't fake it.
        let origin = message.frameInfo.securityOrigin
        guard origin.protocol == "http", origin.host == "127.0.0.1", origin.port == Int(port) else {
            return (nil, "singularity is only available to artifact pages")
        }
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else {
            return (nil, "malformed message")
        }
        guard let state else { return (nil, "browser is shutting down") }

        switch type {
        case "prompt":
            guard let text = body["text"] as? String, !text.isEmpty else { return (nil, "prompt needs text") }
            guard text.utf8.count <= 100_000 else { return (nil, "prompt text is too long (max 100 kB)") }
            switch await state.sendPromptFromArtifact(text, spaceID: spaceID) {
            case .sent: return (true, nil)
            case .declined: return (false, nil)
            case .noTerminal: return (nil, "no terminal tab in this Space")
            }

        case "open":
            guard let string = body["url"] as? String, let url = URL(string: string),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
                return (nil, "open needs an http(s) URL")
            }
            state.openInNewTab(url, spaceID: spaceID)
            return (true, nil)

        default:
            return (nil, "unknown message type \(type)")
        }
    }
}

enum PromptResult {
    case sent, declined, noTerminal
}
