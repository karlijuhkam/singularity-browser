import AppKit
import Observation
import SingularityCore
import UniformTypeIdentifiers
import WebKit

/// Wraps one WKWebView and acts as its delegate.
///
/// WebKit talks to the app through delegates:
/// - `WKNavigationDelegate`: page loading (allow/cancel a navigation, finished loading, downloads)
/// - `WKUIDelegate`: things a page asks the browser UI for (new windows, JS alert(), file pickers)
/// - `WKDownloadDelegate`: where to save a download
///
/// Page state such as title and URL is read with KVO (key-value observing), the Objective-C
/// change-notification mechanism WKWebView exposes for those properties.
@MainActor
@Observable
final class WebTabController: NSObject {
    let tabID: UUID
    let spaceID: UUID
    /// Artifact pages are not recorded in history and have no favicon.
    let isArtifact: Bool
    @ObservationIgnored let webView: WKWebView
    @ObservationIgnored private weak var state: AppState?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []

    // Mirrored from the web view so SwiftUI can observe them (toolbar buttons, progress bar).
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    private(set) var isLoading = false
    private(set) var estimatedProgress = 0.0

    init(tabID: UUID, spaceID: UUID, configuration: WKWebViewConfiguration, state: AppState?, isArtifact: Bool = false) {
        self.tabID = tabID
        self.spaceID = spaceID
        self.isArtifact = isArtifact
        self.state = state
        self.webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()

        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true // two-finger swipe
        webView.allowsMagnification = true                  // pinch to zoom
        webView.isInspectable = true                         // right-click → Inspect Element

        observeWebView()
    }

    func load(_ url: URL) {
        webView.load(URLRequest(url: url))
    }

    func reload() { webView.reload() }
    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }

    /// Called when the tab is closed.
    func tearDown() {
        observations.forEach { $0.invalidate() }
        observations.removeAll()
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.removeFromSuperview()
    }

    private func observeWebView() {
        // KVO callbacks for WKWebView arrive on the main thread, but Swift can't prove that,
        // so `MainActor.assumeIsolated` tells the compiler (and checks at runtime).
        observations = [
            webView.observe(\.title, options: [.new]) { [weak self] webView, _ in
                MainActor.assumeIsolated { self?.titleOrURLChanged() }
            },
            webView.observe(\.url, options: [.new]) { [weak self] webView, _ in
                MainActor.assumeIsolated { self?.titleOrURLChanged() }
            },
            webView.observe(\.canGoBack, options: [.new]) { [weak self] webView, _ in
                MainActor.assumeIsolated { self?.canGoBack = webView.canGoBack }
            },
            webView.observe(\.canGoForward, options: [.new]) { [weak self] webView, _ in
                MainActor.assumeIsolated { self?.canGoForward = webView.canGoForward }
            },
            webView.observe(\.isLoading, options: [.new]) { [weak self] webView, _ in
                MainActor.assumeIsolated { self?.isLoading = webView.isLoading }
            },
            webView.observe(\.estimatedProgress, options: [.new]) { [weak self] webView, _ in
                MainActor.assumeIsolated { self?.estimatedProgress = webView.estimatedProgress }
            },
        ]
    }

    private func titleOrURLChanged() {
        let title = webView.title.flatMap { $0.isEmpty ? nil : $0 }
        // `url` is briefly nil during some navigations; keep the last known URL then.
        state?.webTabDidChange(tabID: tabID, spaceID: spaceID, title: title, url: webView.url)
    }

    /// Finds the page's declared icon (<link rel="icon">), falling back to /favicon.ico.
    private func fetchFavicon() async {
        guard let pageURL = webView.url, let host = pageURL.host(), let slug = state?.space(spaceID)?.slug else { return }
        guard let favicons = state?.favicons, !favicons.hasIcon(slug: slug, host: host) else { return }

        let script = """
        (() => {
          const link = document.querySelector('link[rel~="icon"]') || document.querySelector('link[rel="apple-touch-icon"]');
          return link ? link.href : null;
        })()
        """
        var iconURL: URL?
        if let href = try? await webView.evaluateJavaScript(script) as? String {
            iconURL = URL(string: href)
        }
        if iconURL == nil || iconURL?.scheme == "data" {
            iconURL = URL(string: "/favicon.ico", relativeTo: pageURL)?.absoluteURL
        }
        guard let iconURL else { return }
        await favicons.fetch(iconURL, slug: slug, host: host)
    }
}

// MARK: - WKNavigationDelegate

extension WebTabController: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        if navigationAction.shouldPerformDownload { return .download }

        guard let url = navigationAction.request.url else { return .allow }

        // Links like mailto:, tel:, zoommtg: are handed to the system (Mail, FaceTime, …).
        let webSchemes: Set<String> = ["http", "https", "about", "data", "blob", "file", "javascript"]
        if let scheme = url.scheme?.lowercased(), !webSchemes.contains(scheme) {
            NSWorkspace.shared.open(url)
            return .cancel
        }

        // Cmd+click on a link opens it in a background tab, like every other browser.
        if navigationAction.navigationType == .linkActivated,
           navigationAction.modifierFlags.contains(.command) {
            state?.openInBackgroundTab(url, spaceID: spaceID, after: tabID)
            return .cancel
        }
        return .allow
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        // Content the web view can't display (zip, dmg, …) or that the server marks as an
        // attachment is downloaded instead.
        let disposition = (navigationResponse.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition") ?? ""
        if !navigationResponse.canShowMIMEType || disposition.lowercased().hasPrefix("attachment") {
            return .download
        }
        return .allow
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !isArtifact else { return }
        if let url = webView.url {
            state?.recordVisit(spaceID: spaceID, url: url, title: webView.title ?? "")
        }
        Task { await fetchFavicon() }
    }

    /// The page's web content process crashed (or was killed for memory). Reload it.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }
}

// MARK: - WKUIDelegate

extension WebTabController: WKUIDelegate {
    /// `window.open(...)` and `target="_blank"` links. See `AppState.openPopup`.
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        state?.openPopup(from: tabID, spaceID: spaceID, configuration: configuration, url: navigationAction.request.url)
    }

    /// The page called `window.close()`.
    func webViewDidClose(_ webView: WKWebView) {
        state?.closeTab(tabID, in: spaceID)
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async {
        let alert = NSAlert()
        alert.messageText = frame.request.url?.host() ?? "This page says"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        _ = await present(alert)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async -> Bool {
        let alert = NSAlert()
        alert.messageText = frame.request.url?.host() ?? "This page says"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        return await present(alert) == .alertFirstButtonReturn
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo
    ) async -> String? {
        let alert = NSAlert()
        alert.messageText = frame.request.url?.host() ?? "This page says"
        alert.informativeText = prompt
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = defaultText ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        return await present(alert) == .alertFirstButtonReturn ? field.stringValue : nil
    }

    /// `<input type="file">`.
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo) async -> [URL]? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        let response: NSApplication.ModalResponse
        if let window = webView.window {
            response = await panel.beginSheetModal(for: window)
        } else {
            response = panel.runModal()
        }
        return response == .OK ? panel.urls : nil
    }

    /// Shows an alert as a sheet on the browser window (or as a free-standing dialog if the
    /// tab isn't on screen) and waits for the user to answer.
    private func present(_ alert: NSAlert) async -> NSApplication.ModalResponse {
        guard let window = webView.window else { return alert.runModal() }
        return await alert.beginSheetModal(for: window)
    }
}

// MARK: - WKDownloadDelegate

extension WebTabController: WKDownloadDelegate {
    /// Saves straight into ~/Downloads, adding " (2)", " (3)", … if the name is taken.
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String) async -> URL? {
        let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let name = (suggestedFilename as NSString).lastPathComponent // never trust a path from the server
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = folder.appending(path: name)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let numbered = ext.isEmpty ? "\(base) (\(counter))" : "\(base) (\(counter)).\(ext)"
            candidate = folder.appending(path: numbered)
            counter += 1
        }
        return candidate
    }

    func downloadDidFinish(_ download: WKDownload) {
        // Makes the Downloads stack in the Dock bounce, as Safari does.
        if let url = download.progress.fileURL {
            DistributedNotificationCenter.default().post(name: .init("com.apple.DownloadFileFinished"), object: url.path)
        }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        NSLog("Singularity: download failed: \(error.localizedDescription)")
    }
}
