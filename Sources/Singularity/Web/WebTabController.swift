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
    /// The load of the error page itself, from asking for it until it finishes or fails.
    @ObservationIgnored private var errorNavigation: WKNavigation?
    @ObservationIgnored private var errorNavigationURL: URL?
    /// Host of the page this tab is going to (set for every main-frame navigation, redirects
    /// included). Only that host, or the page already shown, may ask for a name and password.
    @ObservationIgnored private var mainFrameHost: String?
    @ObservationIgnored private var lastCrashReload: Date?
    /// Console problems and failed requests of the page, for agents (`read_console`,
    /// `read_network`). Only filled for sites the owner switched on; see `PageCaptureScript`.
    @ObservationIgnored private var capture = PageCapture()
    /// The site `capture` belongs to. Entries of one site are never shown for another.
    @ObservationIgnored private var captureSite: String?
    /// Bumped by ⌘F so an already open find bar takes the keyboard again.
    private(set) var findFocusToken = 0

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

    // MARK: - Console and network capture

    func recordCapture(json: String, site: String) {
        if captureSite != site {
            capture.clear()
            captureSite = site
        }
        capture.record(json: json)
    }

    /// What was captured for `site` (empty when the tab's capture belongs to another site).
    func capture(forSite site: String) -> PageCapture {
        captureSite == site ? capture : PageCapture()
    }

    /// Forgets what was captured (the site was switched off, or the tab left the site).
    func clearCapture() {
        capture.clear()
        captureSite = nil
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
        // answer (approvals time out on their own), then for the load it may start.
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
        findFocusToken += 1
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
        // Artifact pages need the app's token on their first request; a plain retry would be
        // refused, so they keep WebKit's own behaviour.
        guard !isArtifact, LoadErrorPage.shouldShow(domain: nsError.domain, code: nsError.code) else { return }
        let url = (nsError.userInfo[NSURLErrorFailingURLErrorKey] as? URL)
            ?? (nsError.userInfo[NSURLErrorFailingURLStringErrorKey] as? String).flatMap(URL.init(string:))
            ?? webView.url
        guard let url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        let html = LoadErrorPage.html(url: url.absoluteString, message: nsError.localizedDescription)
        errorNavigationURL = url
        errorNavigation = webView.loadSimulatedRequest(URLRequest(url: url), responseHTML: html)
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
        // The error page's title is not the page's name: keep the saved one (pinned tabs offline).
        let showingError = failedURL != nil || errorNavigation != nil
        let title = showingError ? nil : webView.title.flatMap { $0.isEmpty ? nil : $0 }
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
        if navigationAction.targetFrame?.isMainFrame ?? false { mainFrameHost = url.host() }

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
        if navigation === errorNavigation, errorNavigation != nil {
            errorNavigation = nil
            failedURL = errorNavigationURL
            return
        }
        guard !isArtifact else { return }
        if let url = webView.url {
            state?.recordVisit(spaceID: spaceID, url: url, title: webView.title ?? "")
        }
        Task { await fetchFavicon() }
    }

    /// The load failed before any content arrived (no connection, unknown host, bad certificate…).
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if navigation === errorNavigation { errorNavigation = nil; return } // never loop on our own page
        showLoadError(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if navigation === errorNavigation { errorNavigation = nil }
    }

    /// Content of a new page started arriving: the error page (if any) is gone.
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        if navigation !== errorNavigation { failedURL = nil }
        // The tab left the site its console and network entries belong to: they go.
        if captureSite != nil, SiteInfo.site(of: webView.url) != captureSite { clearCapture() }
    }

    /// Sites behind a username and password (HTTP Basic/Digest, common on staging servers).
    /// Everything else (certificates, client certificates) keeps WebKit's default handling.
    func webView(_ webView: WKWebView, respondTo challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let space = challenge.protectionSpace
        let passwordMethods = [NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest, NSURLAuthenticationMethodNTLM]
        guard passwordMethods.contains(space.authenticationMethod) else { return (.performDefaultHandling, nil) }
        // Only the page itself may ask, and only while you can see it. An image or frame from
        // another site could otherwise show a password dialog under its own name, over and over;
        // and a tab in the background (e.g. one an agent opened) would ask out of nowhere.
        let isPageItself = space.host == mainFrameHost || space.host == webView.url?.host()
        // "Use no credential" lets the server's own "401 Unauthorized" page show, instead of
        // leaving the tab silently on the previous page.
        guard webView.window != nil, isPageItself || space.isProxy() else { return (.useCredential, nil) }
        // A credential from earlier in this session is tried first; after three wrong answers, give up.
        if challenge.previousFailureCount == 0, challenge.proposedCredential?.hasPassword == true {
            return (.performDefaultHandling, nil)
        }
        guard challenge.previousFailureCount < 3 else { return (.useCredential, nil) }

        let alert = NSAlert()
        alert.messageText = space.isProxy() ? "Log in to the proxy \(space.host)" : "Log in to \(space.host)"
        // The realm is text chosen by the server: keep it short and clearly quoted.
        var info = space.realm.flatMap { $0.isEmpty ? nil : "The site says: “\(String($0.prefix(80)))”." } ?? ""
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
        guard await present(alert) == .alertFirstButtonReturn else { return (.useCredential, nil) }
        // `.forSession`: remembered until the app quits, never written to the keychain.
        return (.useCredential, URLCredential(user: user.stringValue, password: password.stringValue, persistence: .forSession))
    }

    /// The page's web content process crashed (or was killed for memory). Reload it.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // A page that crashes every time would otherwise reload forever: one retry per 10 seconds.
        let now = Date()
        defer { lastCrashReload = now }
        if let last = lastCrashReload, now.timeIntervalSince(last) < 10, let url = webView.url,
           ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            let html = LoadErrorPage.html(url: url.absoluteString, message: "This page keeps crashing, so Singularity stopped reloading it.")
            errorNavigationURL = url
            errorNavigation = webView.loadSimulatedRequest(URLRequest(url: url), responseHTML: html)
            return
        }
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

    // alert() / confirm() / prompt(). A tab that isn't on screen gets the "cancelled" answer at
    // once: a dialog from a page you can't see would block the whole app, and a page could repeat it.
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async {
        guard webView.window != nil else { return }
        let alert = NSAlert()
        alert.messageText = frame.request.url?.host() ?? "This page says"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        _ = await present(alert)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async -> Bool {
        guard webView.window != nil else { return false }
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
        guard webView.window != nil else { return nil }
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

    /// A page asks for the camera or the microphone. The owner's choice for the site (site
    /// settings: Ask / Allow / Block) decides; "Ask" is WebKit's own question, as before.
    func webView(_ webView: WKWebView, decideMediaCapturePermissionsFor origin: WKSecurityOrigin,
                 initiatedBy frame: WKFrameInfo, type: WKMediaCaptureType) async -> WKPermissionDecision {
        guard let space = state?.space(spaceID), let pageSite = SiteInfo.site(of: webView.url) else { return .prompt }
        var components = URLComponents()
        components.scheme = origin.protocol
        components.host = origin.host
        if origin.port != 0 { components.port = origin.port }
        let kind: MediaRules.Kind
        switch type {
        case .camera: kind = .camera
        case .microphone: kind = .microphone
        case .cameraAndMicrophone: kind = .cameraAndMicrophone
        @unknown default: return .prompt
        }
        switch MediaRules.decide(kind, settings: space.settings(forSite: pageSite),
                                 requestingSite: SiteInfo.site(of: components.url), pageSite: pageSite) {
        case .grant: return .grant
        case .deny: return .deny
        case .prompt: return .prompt
        }
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
    /// Saves straight into ~/Downloads, adding " (2)", " (3)", … if the name is taken, and lists
    /// the download in the sidebar (`DownloadCenter`).
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String) async -> URL? {
        if let state {
            return state.downloads.begin(download, suggestedFilename: suggestedFilename,
                                         expectedBytes: response.expectedContentLength)
        }
        // No app state (tests): just pick the file.
        let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        return DownloadNaming.destination(suggestedFilename: suggestedFilename, folder: folder) {
            FileManager.default.fileExists(atPath: $0.path)
        }
    }

    func downloadDidFinish(_ download: WKDownload) {
        state?.downloads.finished(download)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        NSLog("Singularity: download failed: \(error.localizedDescription)")
        state?.downloads.failed(download, error: error)
    }
}
