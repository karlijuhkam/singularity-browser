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

    /// Set while an agent's click or type runs on this tab. Every main-frame navigation during
    /// that time is checked: it gets the URL and whether it is a form submission, and returns
    /// whether it may go ahead (it may ask the user first). Catches JavaScript-driven submits and
    /// redirects that couldn't be predicted before the click.
    @ObservationIgnored var agentNavigationGuard: (@MainActor (URL, Bool) async -> Bool)?
    /// Navigations currently waiting for the user's answer (the agent's call waits for these).
    @ObservationIgnored private(set) var pendingNavigationApprovals = 0

    // Mirrored from the web view so SwiftUI can observe them (toolbar buttons, progress bar).
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    private(set) var isLoading = false
    private(set) var estimatedProgress = 0.0

    // Find in page (⌘F). WKWebView on macOS has no find bar of its own; `FindBar` draws ours.
    var isFindBarVisible = false
    var findText = ""
    /// False after a search that found nothing (the bar turns the field red).
    private(set) var findFailed = false

    /// The URL whose load failed, while the error page for it is showing (so Reload retries it).
    @ObservationIgnored private var failedURL: URL?
    /// Set between asking for the error page and it finishing loading.
    @ObservationIgnored private var pendingErrorURL: URL?

    init(tabID: UUID, spaceID: UUID, configuration: WKWebViewConfiguration, state: AppState?, isArtifact: Bool = false) {
        self.tabID = tabID
        self.spaceID = spaceID
        self.isArtifact = isArtifact
        self.state = state
        // A realistic size even before the tab is shown: tabs that agents open in the background
        // are laid out (and screenshotted) at this size until the user looks at them.
        self.webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 800), configuration: configuration)
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

    /// Waits until the page has finished loading (or `timeout` passes).
    func waitUntilLoaded(timeout: Duration = .seconds(20)) async {
        let deadline = ContinuousClock.now + timeout
        // A load requested a moment ago may not have flipped `isLoading` yet.
        try? await Task.sleep(for: .milliseconds(100))
        while webView.isLoading, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        // A navigation held for the user's approval doesn't count as loading yet; wait for the
        // answer (approval sheets time out on their own), then for the load it may start.
        if pendingNavigationApprovals > 0 {
            while pendingNavigationApprovals > 0 {
                try? await Task.sleep(for: .milliseconds(100))
            }
            try? await Task.sleep(for: .milliseconds(100))
            while webView.isLoading, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    /// What acting on an element would do (for approvals); see `inspect` in PageAgentScript.
    struct ElementInfo: Decodable {
        let description: String
        let submits: Bool
        let href: String?
        let isPassword: Bool
    }

    func inspect(ref: Int) async throws -> ElementInfo {
        let json = try await callPageAgent("inspect(ref)", arguments: ["ref": ref])
        return try JSONDecoder().decode(ElementInfo.self, from: Data(json.utf8))
    }

    /// Calls a function of the page agent (PageAgentScript) in its isolated world, e.g.
    /// `callPageAgent("click(ref)", arguments: ["ref": 12])`. Returns its string result.
    func callPageAgent(_ call: String, arguments: [String: Any]) async throws -> String {
        let body = """
        if (!window.__singularityAgent) throw new Error("This page can't be read (it is not an HTML document, or is still loading).");
        return window.__singularityAgent.\(call);
        """
        let result = try await webView.callAsyncJavaScript(body, arguments: arguments, in: nil, contentWorld: PageAgentScript.world)
        return result as? String ?? ""
    }

    func reload() {
        // On the error page, "reload" means trying the failed address again.
        if let failedURL { load(failedURL) } else { webView.reload() }
    }

    // MARK: Find, zoom, print

    func showFindBar() {
        isFindBarVisible = true
    }

    func hideFindBar() {
        isFindBarVisible = false
        findFailed = false
        webView.window?.makeFirstResponder(webView)
    }

    /// Selects and scrolls to the next (or previous) match of `findText`, wrapping around.
    func find(backwards: Bool = false) {
        guard !findText.isEmpty else { findFailed = false; return }
        let configuration = WKFindConfiguration()
        configuration.backwards = backwards
        configuration.caseSensitive = false
        configuration.wraps = true
        let text = findText
        Task {
            let result = try? await webView.find(text, configuration: configuration)
            // Ignore the answer if the text changed while WebKit was searching.
            if text == findText { findFailed = !(result?.matchFound ?? false) }
        }
    }

    func zoom(larger: Bool) { webView.pageZoom = PageZoom.next(from: webView.pageZoom, larger: larger) }
    func resetZoom() { webView.pageZoom = 1.0 }

    func printPage() {
        guard let window = webView.window else { return }
        let operation = webView.printOperation(with: NSPrintInfo.shared)
        // WebKit's print view starts with an empty frame, and AppKit refuses to print that.
        operation.view?.frame = webView.bounds
        operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }

    /// Replaces the blank page left by a failed load with an explanation. The address stays the
    /// failed one, so the sidebar, ⌘L and Reload keep working on it.
    private func showLoadError(_ error: Error) {
        let nsError = error as NSError
        guard LoadErrorPage.shouldShow(domain: nsError.domain, code: nsError.code) else { return }
        let url = (nsError.userInfo[NSURLErrorFailingURLErrorKey] as? URL)
            ?? (nsError.userInfo[NSURLErrorFailingURLStringErrorKey] as? String).flatMap(URL.init(string:))
            ?? webView.url
        guard let url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        pendingErrorURL = url
        let html = LoadErrorPage.html(url: url.absoluteString, message: nsError.localizedDescription)
        webView.loadSimulatedRequest(URLRequest(url: url), responseHTML: html)
    }
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

        // During an agent's click/type, navigations of the page itself are checked first.
        if let guardCheck = agentNavigationGuard, navigationAction.targetFrame?.isMainFrame ?? true,
           ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            let isForm = navigationAction.navigationType == .formSubmitted || navigationAction.navigationType == .formResubmitted
            pendingNavigationApprovals += 1
            let allowed = await guardCheck(url, isForm)
            pendingNavigationApprovals -= 1
            if !allowed { return .cancel }
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
        // The error page finishing is not a visit: keep it out of history.
        if let url = pendingErrorURL {
            pendingErrorURL = nil
            failedURL = url
            return
        }
        failedURL = nil
        guard !isArtifact else { return }
        if let url = webView.url {
            state?.recordVisit(spaceID: spaceID, url: url, title: webView.title ?? "")
        }
        Task { await fetchFavicon() }
    }

    /// The load failed before any content arrived (no connection, unknown host, bad certificate…).
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        showLoadError(error)
    }

    /// Sites behind a username and password (HTTP Basic/Digest, common on staging servers).
    /// Everything else (certificates, client certificates) keeps WebKit's default handling.
    func webView(_ webView: WKWebView, respondTo challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let space = challenge.protectionSpace
        let passwordMethods = [NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest, NSURLAuthenticationMethodNTLM]
        guard passwordMethods.contains(space.authenticationMethod) else { return (.performDefaultHandling, nil) }
        // A credential from earlier in this session is tried first; after three wrong answers, give up.
        if challenge.previousFailureCount == 0, challenge.proposedCredential?.hasPassword == true {
            return (.performDefaultHandling, nil)
        }
        guard challenge.previousFailureCount < 3 else { return (.cancelAuthenticationChallenge, nil) }

        let alert = NSAlert()
        alert.messageText = "Log in to \(space.host)"
        var info = space.realm.flatMap { $0.isEmpty ? nil : "The site says: “\($0)”." } ?? ""
        if space.protocol != "https", !space.isProxy() {
            info += (info.isEmpty ? "" : "\n") + "This connection is not encrypted: the password can be read on the way."
        }
        if challenge.previousFailureCount > 0 { info += (info.isEmpty ? "" : "\n") + "That name or password was not accepted." }
        alert.informativeText = info
        let user = NSTextField(frame: NSRect(x: 0, y: 30, width: 260, height: 24))
        user.placeholderString = "Name"
        user.stringValue = challenge.proposedCredential?.user ?? ""
        let password = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        password.placeholderString = "Password"
        let fields = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 54))
        fields.addSubview(user)
        fields.addSubview(password)
        user.nextKeyView = password
        alert.accessoryView = fields
        alert.addButton(withTitle: "Log In")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = user
        guard await present(alert) == .alertFirstButtonReturn else { return (.cancelAuthenticationChallenge, nil) }
        // `.forSession`: remembered until the app quits, never written to the keychain.
        return (.useCredential, URLCredential(user: user.stringValue, password: password.stringValue, persistence: .forSession))
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
    fileprivate func present(_ alert: NSAlert) async -> NSApplication.ModalResponse {
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
