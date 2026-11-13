import Foundation
import SingularityCore
import WebKit

/// One plugin's own page (`panel.page`) in one web view, and the small bridge between that page
/// and the plugin's background program.
///
/// The web view is locked down; the frame around it (panel or tab) belongs to someone else:
/// - its own non-persistent data store: no cookies or storage shared with any Space, nothing kept;
/// - its content comes only from `PluginPageServer` (`singularity-plugin://<id>/`), whose
///   Content-Security-Policy allows no fetch, image, frame, form or other load from anywhere else;
/// - WebRTC is switched off (`RTCPeerConnection` could otherwise send UDP and DNS traffic, which
///   no CSP directive covers; see `switchOffPeerConnections`);
/// - the main frame may only show the plugin's own origin: every other navigation, new windows,
///   downloads, camera and microphone are refused, and JavaScript dialogs are not shown. After
///   `tearDown` every navigation is refused, for as long as the web view lives (the page's
///   JavaScript can still be running then);
/// - none of the scripts web tabs get (page agent, console/network capture, plugins' page
///   scripts), so no agent tool can read it.
///
/// The page (`panel.page`) is served at `/`. An HTML page must sit at the top of the plugin
/// folder, or its relative links would point to the wrong place; a script page may be anywhere.
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
    /// When the page was last loaded again after its web content process died, and whether such a
    /// reload is waiting for its turn (`reloadAfterCrash`).
    private var lastCrashReload: ContinuousClock.Instant?
    private var crashReloadWaiting = false
    /// At most one reload per this long after crashes, so a page that keeps crashing its web
    /// content process doesn't reload in a tight loop. A `var` so tests can shorten it.
    var crashReloadSpacing: Duration = .seconds(5)

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
        if !Self.switchOffPeerConnections(configuration.preferences) {
            // This WebKit has no such preference: take the constructors away in every frame.
            configuration.userContentController.addUserScript(WKUserScript(
                source: Self.noPeerConnectionsSource, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        }
        configuration.userContentController.addUserScript(WKUserScript(
            source: Self.scriptSource(pluginID: pluginID), injectionTime: .atDocumentStart, forMainFrameOnly: true))
        configuration.userContentController.addScriptMessageHandler(bridge, contentWorld: .page, name: Self.handlerName)

        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isInspectable = true
        // A force click on a link would otherwise preview that page, from anywhere, in a popover.
        webView.allowsLinkPreview = false
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.load(URLRequest(url: PluginPageServer.rootURL(pluginID: pluginID)))
    }

    /// Switches WebRTC off with WebKit's "peerConnectionEnabled" preference, set by key like
    /// `developerExtrasEnabled` (it has no Swift property). Setting a key WebKit doesn't know raises
    /// an Objective-C exception, which Swift can't catch and which would end the app, so the setter
    /// that key-value coding would call is looked for first. Returns false when it isn't there.
    static func switchOffPeerConnections(_ preferences: WKPreferences) -> Bool {
        guard preferences.responds(to: NSSelectorFromString("_setPeerConnectionEnabled:")) else { return false }
        preferences.setValue(false, forKey: "peerConnectionEnabled")
        return true
    }

    /// The fallback when the preference is missing: no WebRTC constructors in any frame.
    static let noPeerConnectionsSource = """
        for (const name of ["RTCPeerConnection", "webkitRTCPeerConnection", "RTCDataChannel"]) {
          try { delete window[name]; } catch (error) {}
          try { Object.defineProperty(window, name, { value: undefined, writable: false, configurable: false }); } catch (error) {}
        }
        """

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

    /// After the web content process died (memory pressure, a WebKit crash) the web view is blank:
    /// load the page again, at once the first time, then at most once per `crashReloadSpacing`.
    func reloadAfterCrash() {
        guard !tornDown, !crashReloadWaiting else { return }
        let wait = lastCrashReload.map { crashReloadSpacing - (ContinuousClock.now - $0) } ?? .zero
        guard wait > .zero else {
            lastCrashReload = .now
            reload()
            return
        }
        crashReloadWaiting = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: wait)
            guard let self else { return }
            self.crashReloadWaiting = false
            self.lastCrashReload = .now
            self.reload()
        }
    }

    /// Stops the page for good: no more messages either way. The web view can't be used again.
    ///
    /// The page's JavaScript may keep running until the web view is released (a timer, a promise),
    /// and the policy doesn't cover leaving the page, so navigation stays refused: the delegates
    /// become `ClosedPageGuard`, which refuses everything and, unlike this host, lives as long as
    /// the app (WebKit holds delegates weakly).
    func tearDown() {
        tornDown = true
        loaded = false
        webView.stopLoading()
        // The content controller holds its message handlers strongly; let the bridge go.
        webView.configuration.userContentController.removeAllScriptMessageHandlers()
        webView.configuration.userContentController.removeAllUserScripts()
        webView.navigationDelegate = ClosedPageGuard.shared
        webView.uiDelegate = ClosedPageGuard.shared
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
        // only our origin, never a download, and nothing at all once torn down.
        guard !tornDown, !navigationAction.shouldPerformDownload, navigationAction.targetFrame?.isMainFrame == true,
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
        reloadAfterCrash()
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

/// The delegates of a torn-down page: every navigation, window, download, dialog and camera or
/// microphone request is refused. One for the app, so it outlives every host.
@MainActor
private final class ClosedPageGuard: NSObject, WKNavigationDelegate, WKUIDelegate {
    static let shared = ClosedPageGuard()

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        .cancel
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        .cancel
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        nil
    }

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
