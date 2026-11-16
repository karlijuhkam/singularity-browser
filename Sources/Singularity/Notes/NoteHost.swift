import Foundation
import SingularityCore
import WebKit
import os

/// Visible with: log stream --level debug --predicate 'subsystem == "dev.roosa.Singularity" AND category == "notes"'
let notesLog = Logger(subsystem: "dev.roosa.Singularity", category: "notes")

/// One note tab: the editor's page in a locked web view, and the note's file.
///
/// The page is Singularity's own code (the bundled editor, served by `NotePageServer`), but what
/// it shows is a file anyone may have written, so the web view is locked like a plugin's page
/// (`PluginPageHost`): a non-persistent data store, no network (the page's policy), WebRTC off,
/// the main frame may only show the editor's own origin, no new windows, downloads, dialogs,
/// camera or microphone, and none of the scripts web tabs get, so no agent tool can read it.
///
/// The page can't touch the disk. Everything goes through one message handler, answered here:
///
///     load   → the note's title and text
///     save   → writes the text, unless the file changed underneath (`NoteFiles.saveDecision`)
///     rename → renames the file (the title is the file's name)
///     image  → saves a pasted picture into `assets/` next to the note
///     open   → opens an http(s) link in a new tab of the note's Space
///
/// All of it stays inside the note's folder (`NoteFiles.Location`): the Space's `notes/` folder,
/// or, for a Markdown file opened from elsewhere, that file's own folder.
@MainActor
final class NoteHost: NSObject {
    static let handlerName = "singularityNote"

    let tabID: UUID
    let webView: WKWebView
    /// The note's folder and the file's path inside it. A rename changes the path.
    private(set) var location: NoteFiles.Location
    private let server: NotePageServer
    private let bridge: NoteBridge
    private var tornDown = false
    /// The text the editor last got from the disk or wrote to it; nil while it has none. A save is
    /// only written while the file still says this (or is gone).
    private var known: String?
    private var lastCrashReload: ContinuousClock.Instant?

    /// The file was renamed: the new path inside the note's folder.
    var onRename: ((String) -> Void)?
    /// The owner ⌘-clicked a link (or pressed Open on it).
    var onOpenLink: ((URL) -> Void)?
    /// Whether another tab already shows the note at this path (a rename must not land on it).
    var isOpenElsewhere: ((String) -> Bool)?

    /// Whether the editor's files are there: in the app bundle, not next to a bare debug binary.
    static func editorIsBundled(_ folder: URL = NotePageServer.bundledEditorFolder) -> Bool {
        FileManager.default.fileExists(atPath: folder.appending(path: "editor.js").path)
    }

    init(tabID: UUID, location: NoteFiles.Location, editorFolder: URL = NotePageServer.bundledEditorFolder) {
        self.tabID = tabID
        self.location = location
        let bridge = NoteBridge()
        self.bridge = bridge
        // The server asks where the note is at every request (a rename moves it); the box is what
        // both sides hold, because the host itself doesn't exist yet when the server is made.
        let place = PlaceBox(location)
        self.place = place
        let server = NotePageServer(editorFolder: editorFolder) { place.location }
        self.server = server

        let configuration = WKWebViewConfiguration()
        // Nothing kept, nothing shared with any Space.
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(server, forURLScheme: NotePageServer.scheme)
        // Right-click → Inspect Element, as web tabs have (set by key: it has no Swift property).
        configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")
        if !PluginPageHost.switchOffPeerConnections(configuration.preferences) {
            configuration.userContentController.addUserScript(WKUserScript(
                source: PluginPageHost.noPeerConnectionsSource, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        }
        configuration.userContentController.addScriptMessageHandler(bridge, contentWorld: .page, name: Self.handlerName)

        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isInspectable = true
        // A force click on a link would otherwise preview that page, from anywhere, in a popover.
        webView.allowsLinkPreview = false
        super.init()
        bridge.host = self
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.load(URLRequest(url: NotePageServer.rootURL))
    }

    /// The note's place, shared with the server.
    private let place: PlaceBox

    @MainActor
    private final class PlaceBox {
        var location: NoteFiles.Location
        init(_ location: NoteFiles.Location) { self.location = location }
    }

    // MARK: The file

    private var file: URL? { NoteFiles.file(forPath: location.path, root: location.root) }

    /// The file's text; nil when there is no file. Throws what the page should be told.
    private func readFile() throws -> String? {
        guard let file else { throw NoteError("its place on disk can't be used") }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path) else { return nil }
        guard (attributes[.size] as? Int ?? 0) <= NoteFiles.maxNoteBytes else { throw NoteError("the file is larger than 2 MB") }
        let data = try Data(contentsOf: file)
        guard let text = String(data: data, encoding: .utf8) else { throw NoteError("the file isn't UTF-8 text") }
        return text
    }

    fileprivate func load() throws -> [String: Any] {
        let text = try readFile()
        known = text
        return ["title": NoteFiles.title(ofPath: location.path), "markdown": text ?? "", "exists": text != nil]
    }

    fileprivate func save(markdown: String, force: Bool) throws -> [String: Any] {
        guard markdown.utf8.count <= NoteFiles.maxNoteBytes else { throw NoteError("the note is larger than 2 MB") }
        guard let file else { throw NoteError("its place on disk can't be used") }
        // A file that can't be read (too large, not text) is never overwritten without being asked.
        let onDisk = try readFile()
        guard NoteFiles.saveDecision(known: known, onDisk: onDisk, force: force) == .write else { return ["conflict": true] }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        // `.atomic`: written to a temporary file first, then moved into place.
        try Data(markdown.utf8).write(to: file, options: .atomic)
        known = markdown
        return ["ok": true]
    }

    fileprivate func rename(title: String) throws -> [String: Any] {
        guard let newPath = NoteFiles.renamedPath(location.path, title: title) else { throw NoteError("that name can't be used") }
        let newTitle = NoteFiles.title(ofPath: newPath)
        guard newPath != location.path else { return ["title": newTitle] }
        guard let from = file, let to = NoteFiles.file(forPath: newPath, root: location.root) else {
            throw NoteError("that name can't be used")
        }
        // "notes" → "Notes" is the same file on the usual macOS disk: allowed, not a clash.
        let sameFile = newPath.lowercased() == location.path.lowercased()
        let manager = FileManager.default
        if !sameFile, manager.fileExists(atPath: to.path) || isOpenElsewhere?(newPath) == true {
            throw NoteError("a note called “\(newTitle)” is already there")
        }
        if manager.fileExists(atPath: from.path) {
            try manager.moveItem(at: from, to: to)
        }
        location.path = newPath
        place.location = location
        onRename?(newPath)
        return ["title": newTitle]
    }

    fileprivate func saveImage(name: String, base64: String) throws -> [String: Any] {
        // Four base64 characters carry three bytes.
        guard base64.utf8.count <= NoteFiles.maxImageBytes / 3 * 4 + 4, let data = Data(base64Encoded: base64),
              data.count <= NoteFiles.maxImageBytes else { throw NoteError("it is larger than 10 MB") }
        guard let fileName = NoteFiles.imageName(extension: (name as NSString).pathExtension),
              let file = NoteFiles.newImageFile(name: fileName, notePath: location.path, root: location.root) else {
            throw NoteError("that kind of picture isn't supported")
        }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
        return ["src": NoteFiles.assetsFolder + "/" + fileName]
    }

    fileprivate func open(link: String) {
        guard let url = URL(string: link), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else { return }
        onOpenLink?(url)
    }

    // MARK: From the app

    /// The Space's folder watcher saw the note's file change. Tells the page only when the text
    /// really differs from what the editor has (our own saves arrive here too).
    func fileChangedOnDisk() {
        guard !tornDown, let text = try? readFile(), text != known else { return }
        webView.callAsyncJavaScript("if (window.__noteFileChanged) window.__noteFileChanged();",
                                    arguments: [:], in: nil, in: .page, completionHandler: nil)
    }

    /// Has the page write what is unsaved (and finish a title being typed). Gives up after 2 s.
    func flush() async {
        guard !tornDown else { return }
        // Whichever comes first, the page's answer or the 2 s, resumes the wait; the other is ignored.
        let once = Once()
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            once.action = { done.resume() }
            webView.callAsyncJavaScript("if (window.__noteFlush) await window.__noteFlush();",
                                        arguments: [:], in: nil, in: .page) { _ in
                MainActor.assumeIsolated { once.run() }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { once.run() }
        }
    }

    @MainActor
    private final class Once {
        var action: (() -> Void)?
        func run() {
            action?()
            action = nil
        }
    }

    /// Stops the page for good (see `PluginPageHost.tearDown` for why the guard takes over).
    func tearDown() {
        tornDown = true
        webView.stopLoading()
        webView.configuration.userContentController.removeAllScriptMessageHandlers()
        webView.configuration.userContentController.removeAllUserScripts()
        webView.navigationDelegate = ClosedPageGuard.shared
        webView.uiDelegate = ClosedPageGuard.shared
        webView.removeFromSuperview()
    }

    fileprivate var isTornDown: Bool { tornDown }
}

/// What went wrong, in words the page puts after "This note couldn't be saved: ".
struct NoteError: Error, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

// MARK: - Navigation: only the editor's own page

extension NoteHost: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard !tornDown, !navigationAction.shouldPerformDownload, navigationAction.targetFrame?.isMainFrame == true,
              NotePageServer.isOwn(navigationAction.request.url) else { return .cancel }
        return .allow
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        navigationResponse.canShowMIMEType ? .allow : .cancel
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.cancel { _ in }
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.cancel { _ in }
    }

    /// The web content process died (memory pressure, a WebKit crash): the view is blank. Load the
    /// editor again, at most once per 5 s. Saved text is on disk; only the last moment can be lost.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard !tornDown else { return }
        if let last = lastCrashReload, ContinuousClock.now - last < .seconds(5) { return }
        lastCrashReload = .now
        webView.load(URLRequest(url: NotePageServer.rootURL))
    }
}

extension NoteHost: WKUIDelegate {
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

/// The native end of the page's messages. A separate object, so the content controller (which
/// holds its handlers strongly) doesn't keep the host alive. WebKit says which frame and origin
/// each message came from (`frameInfo`), and a page can't fake that.
@MainActor
private final class NoteBridge: NSObject, WKScriptMessageHandlerWithReply {
    weak var host: NoteHost?

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) async -> (Any?, String?) {
        let frame = message.frameInfo
        guard frame.isMainFrame, frame.securityOrigin.protocol == NotePageServer.scheme,
              frame.securityOrigin.host == NotePageServer.host else {
            return (nil, "only the note editor can send messages")
        }
        guard let host, !host.isTornDown else { return (nil, "the note is closed") }
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else {
            return (nil, "malformed message")
        }
        do {
            switch type {
            case "load":
                return (try host.load(), nil)
            case "save":
                guard let markdown = body["markdown"] as? String else { return (nil, "malformed message") }
                return (try host.save(markdown: markdown, force: body["force"] as? Bool ?? false), nil)
            case "rename":
                guard let title = body["title"] as? String else { return (nil, "malformed message") }
                return (try host.rename(title: title), nil)
            case "image":
                guard let name = body["name"] as? String, let base64 = body["base64"] as? String else {
                    return (nil, "malformed message")
                }
                return (try host.saveImage(name: name, base64: base64), nil)
            case "open":
                guard let url = body["url"] as? String else { return (nil, "malformed message") }
                host.open(link: url)
                return (NSNull(), nil)
            default:
                return (nil, "malformed message")
            }
        } catch {
            notesLog.error("note \(type, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return (nil, error.localizedDescription)
        }
    }
}
