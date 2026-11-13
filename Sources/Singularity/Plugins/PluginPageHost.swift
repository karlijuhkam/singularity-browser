import Foundation
import SingularityCore
import WebKit

/// One plugin's own page (`panel.page`) in one web view, and the small bridge between that page
/// and the plugin's background program.
///
/// The web view is locked down; the frame around it (panel or tab) belongs to someone else:
/// - its own non-persistent data store: no cookies or storage shared with any Space, nothing kept;
/// - its content comes only from `PluginPageServer` (`singularity-plugin://<id>/`), whose
///   Content-Security-Policy allows no network at all;
/// - the main frame may only show the plugin's own origin: every other navigation, new windows,
///   downloads, camera and microphone are refused, and JavaScript dialogs are not shown;
/// - none of the scripts web tabs get (page agent, console/network capture, plugins' page
///   scripts), so no agent tool can read it.
///
/// The page API, defined at document start in the page's own world:
///
///     window.singularity.send(payload)      // → Promise of the background's answer
///     window.singularity.onMessage(handler) // the background's pushes (`post`)
@MainActor
final class PluginPageHost: NSObject {
    static let handlerName = "singularityPanel"

    let pluginID: String
    let webView: WKWebView
    private let server: PluginPageServer
    private let bridge: PanelBridge
    /// True while a page of ours is committed in the web view (pushes are dropped otherwise).
    private var loaded = false
    private var tornDown = false

    /// - Parameters:
    ///   - compile: compiles the plugin's TypeScript/TSX (the app passes its `ArtifactScriptService`).
    ///   - send: hands a message from the page to the plugin's background and returns its answer;
    ///     nil when the plugin isn't running or didn't answer.
    init(pluginID: String, folder: URL, manifest: PluginManifest,
         compile: @escaping PluginPageServer.Compile = PluginPageHost.bundledCompile,
         send: @escaping (JSONValue) async -> JSONValue?) {
        self.pluginID = pluginID
        // Without a panel there is no page: "/" is then 404.
        server = PluginPageServer(pluginID: pluginID, folder: folder, entry: manifest.panel?.page ?? "", compile: compile)
        bridge = PanelBridge(pluginID: pluginID, send: send)

        // A configuration of its own, not the one web tabs share.
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(server, forURLScheme: PluginPageServer.scheme)
        // Right-click → Inspect Element, as web tabs have (a WebKit preference without a Swift
        // property, set by key; see WebViewRegistry.configuration).
        configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")
        configuration.userContentController.addUserScript(WKUserScript(
            source: Self.scriptSource(pluginID: pluginID), injectionTime: .atDocumentStart, forMainFrameOnly: true))
        configuration.userContentController.addScriptMessageHandler(bridge, contentWorld: .page, name: Self.handlerName)

        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isInspectable = true
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.load(URLRequest(url: PluginPageServer.rootURL(pluginID: pluginID)))
    }

    /// Compiles with the Bun and plugin host inside the app bundle (as `AppState` sets up the
    /// artifact servers' `ArtifactScriptService`).
    nonisolated static let bundledCompile: PluginPageServer.Compile = { file in
        await bundledScripts.javascript(for: file)
    }

    private nonisolated static let bundledScripts: ArtifactScriptService = {
        let bundle = Bundle.main.bundleURL
        return ArtifactScriptService(runtime: bundle.appending(path: "Contents/Helpers/bun"),
                                     hostFolder: bundle.appending(path: "Contents/Resources/plugin-host", directoryHint: .isDirectory))
    }()

    /// Delivers a push from the background to the page's `onMessage` handler (kept until the page
    /// sets one). Dropped when no page is loaded.
    func post(_ payload: JSONValue) {
        guard loaded, !tornDown,
              let data = try? JSONEncoder().encode(payload) else { return }
        // The payload travels as JSON text in an argument, never pasted into the script.
        webView.callAsyncJavaScript(
            "const deliver = window.__singularityPanelDeliver; if (deliver) deliver(JSON.parse(json));",
            arguments: ["json": String(decoding: data, as: UTF8.self)], in: nil, in: .page, completionHandler: nil)
    }

    /// Loads the page again from the start (also after its web content process died).
    func reload() {
        guard !tornDown else { return }
        webView.load(URLRequest(url: PluginPageServer.rootURL(pluginID: pluginID)))
    }

    /// Stops the page for good: no more messages either way. The web view can't be used again.
    func tearDown() {
        tornDown = true
        loaded = false
        webView.stopLoading()
        // The content controller holds its message handlers strongly; let the bridge go.
        webView.configuration.userContentController.removeAllScriptMessageHandlers()
        webView.configuration.userContentController.removeAllUserScripts()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.removeFromSuperview()
    }

    /// The page API. Only defined on the plugin's own origin; the native side checks the origin of
    /// every message again (`PanelBridge`).
    static func scriptSource(pluginID: String) -> String {
        // The id is `[a-z0-9-]` (PluginManifest), so it needs no escaping; JSON-quoted all the same.
        let origin = String(decoding: (try? JSONEncoder().encode("\(PluginPageServer.scheme)://\(pluginID)")) ?? Data("\"\"".utf8),
                            as: UTF8.self)
        return """
        (() => {
          if (location.origin !== \(origin)) return;
          const handlers = window.webkit.messageHandlers;
          const waiting = [];
          let handler = null;
          const deliver = (payload) => {
            if (!handler) { if (waiting.length < 1000) waiting.push(payload); return; }
            try { handler(payload); } catch (error) { console.error(error); }
          };
          const api = {
            /** Sends a JSON-able value to the plugin's background; resolves with its answer. */
            send(payload) {
              let json;
              try { json = JSON.stringify(payload); } catch (error) { return Promise.reject(error); }
              return handlers.\(handlerName).postMessage({ type: "send", json: json === undefined ? "null" : json });
            },
            /** Receives what the background pushes; messages that came before a handler wait for it. */
            onMessage(next) {
              if (typeof next !== "function") throw new TypeError("onMessage needs a function");
              handler = next;
              for (const payload of waiting.splice(0)) deliver(payload);
            },
          };
          Object.defineProperty(window, "singularity", { value: Object.freeze(api), writable: false, configurable: false });
          Object.defineProperty(window, "__singularityPanelDeliver", { value: deliver, writable: false, configurable: false });
        })();
        """
    }
}

// MARK: - Navigation: only the plugin's own origin

extension PluginPageHost: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        // Frames are refused by the policy (frame-src 'none') and here too: only the main frame,
        // only our origin, never a download.
        guard !navigationAction.shouldPerformDownload, navigationAction.targetFrame?.isMainFrame == true,
              PluginPageServer.isOwn(navigationAction.request.url, pluginID: pluginID) else { return .cancel }
        return .allow
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        // What the web view can't show would otherwise become a download.
        navigationResponse.canShowMIMEType ? .allow : .cancel
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.cancel { _ in }
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.cancel { _ in }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        loaded = false
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        loaded = !tornDown && PluginPageServer.isOwn(webView.url, pluginID: pluginID)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        loaded = false
    }
}

// MARK: - No windows, dialogs, camera or microphone

extension PluginPageHost: WKUIDelegate {
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        nil
    }

    // alert() / confirm() / prompt() are answered at once, as if cancelled, and never shown.
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo) async {}

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo) async -> Bool { false }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo) async -> String? { nil }

    func webView(_ webView: WKWebView, decideMediaCapturePermissionsFor origin: WKSecurityOrigin,
                 initiatedBy frame: WKFrameInfo, type: WKMediaCaptureType) async -> WKPermissionDecision {
        .deny
    }
}

/// The native end of `window.singularity.send`: the message handler "singularityPanel".
///
/// WebKit delivers each message with `frameInfo`, which says which frame and security origin it
/// came from; a page can't fake it. Whatever we return resolves the page's Promise; an error string
/// rejects it. A separate object, so the content controller (which holds its handlers strongly)
/// doesn't keep the host alive.
@MainActor
private final class PanelBridge: NSObject, WKScriptMessageHandlerWithReply {
    private let pluginID: String
    private let send: (JSONValue) async -> JSONValue?

    init(pluginID: String, send: @escaping (JSONValue) async -> JSONValue?) {
        self.pluginID = pluginID
        self.send = send
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) async -> (Any?, String?) {
        let frame = message.frameInfo
        guard frame.isMainFrame, frame.securityOrigin.protocol == PluginPageServer.scheme,
              frame.securityOrigin.host == pluginID else {
            return (nil, "only the plugin's own page can send messages")
        }
        // Size (256 KB as JSON text) and shape, as for page scripts' messages.
        switch PluginPageRequest.parse(message.body) {
        case .failure(.tooLarge):
            return (nil, "the message is larger than 256 KB")
        case .failure(.malformed), .success(.click):
            return (nil, "malformed message")
        case .success(.send(let payload, _)):
            guard let reply = await send(payload) else { return (nil, "the plugin isn't running or didn't answer") }
            return (reply.foundationObject, nil)
        }
    }
}
