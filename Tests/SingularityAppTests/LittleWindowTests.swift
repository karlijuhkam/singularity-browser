import AppKit
import Foundation
import Testing
import WebKit
@testable import Singularity
import SingularityCore

extension AppTests {
/// Little windows: a link from another app in its own throwaway window. A real `AppState`, real
/// windows (far off screen, never key) and a local fixture site. Links are handed to the app's own
/// entry point (`openLink`), never through macOS.
@MainActor
@Suite(.serialized) struct LittleWindowTests {
    /// Two Spaces on disk ("Work" selected, then "Personal"), the app state on them, the fixture site.
    private struct Setup {
        let root: URL
        let state: AppState
        let server: LittleFixtureServer
        let work: UUID
        let personal: UUID

        @MainActor func tearDown() {
            for little in state.little.windows { state.little.close(little) }
            TestAppState.shutDown(state)
            server.stop()
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func setUp() throws -> Setup {
        MainRunLoopGuard.start
        let root = TestAppState.makeRoot()
        let store = SpaceStore(paths: Paths(root: root))
        let work = Space(name: "Work", slug: "work", colorHex: "#5E81F4")
        let personal = Space(name: "Personal", slug: "personal", colorHex: "#F28B54")
        try store.save(work)
        try store.save(personal)
        try store.save(AppStateFile(spaceOrder: [work.id, personal.id], selectedSpaceID: work.id))
        let state = TestAppState.make(root: root)
        state.little.staysOffScreen = true
        state.downloads.folder = root.appending(path: "downloads", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: state.downloads.folder, withIntermediateDirectories: true)
        return Setup(root: root, state: state, server: try LittleFixtureServer.start(), work: work.id, personal: personal.id)
    }

    private func modified(_ file: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date
    }

    private func faviconCount(_ setup: Setup, slug: String) -> Int {
        let folder = setup.state.paths.faviconsDirectory(slug)
        return (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.count ?? 0
    }

    @Test func aLinkOpensAWindowAndLeavesNothingInTheSpace() async throws {
        let setup = try setUp()
        defer { setup.tearDown() }
        let state = setup.state
        state.flushSaves()
        let spaceFile = state.paths.spaceFile("work")
        let savedAt = modified(spaceFile)

        let little = try #require(state.little.open(setup.server.url))
        try await waitUntil("the page to load", limit: .seconds(15)) { little.controller.webView.title == "home" && !little.controller.isLoading }
        // Time for what must *not* happen (a history entry, a favicon fetch, a save) to happen.
        try await Task.sleep(for: .milliseconds(700))
        state.flushSaves()

        #expect(little.homeSpaceID == setup.work)
        #expect(little.controller.isLittle)
        #expect(state.space(setup.work)?.tabs.isEmpty == true)
        #expect(state.history(for: setup.work).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: state.paths.historyFile("work").path))
        #expect(faviconCount(setup, slug: "work") == 0)
        #expect(modified(spaceFile) == savedAt, "space.json was rewritten for a little window's page")

        // The title bar: address, the Spaces, the button for the home Space.
        let chrome = try #require(little.chrome)
        try await waitUntil("the title bar to follow the page") { little.window.title == "home" }
        #expect(chrome.addressText == "127.0.0.1:\(setup.server.url.port!)")
        #expect(chrome.spaceTitles == ["Work", "Personal"])
        #expect(chrome.openButtonTitle == "Open in Work")
        #expect(little.window.isVisible)

        // Closing throws everything away.
        state.little.close(little)
        #expect(state.little.windows.isEmpty)
        #expect(!little.window.isVisible)
        #expect(state.web.existingController(little.id) == nil)
        #expect(state.space(setup.work)?.tabs.isEmpty == true)
        #expect(state.history(for: setup.work).isEmpty)
    }

    @Test func everyLinkGetsItsOwnWindow() async throws {
        let setup = try setUp()
        defer { setup.tearDown() }
        let first = try #require(setup.state.little.open(setup.server.url))
        let second = try #require(setup.state.little.open(setup.server.url.appending(path: "two")))
        #expect(setup.state.little.windows.count == 2)
        #expect(first.window !== second.window)
        #expect(first.controller.webView !== second.controller.webView)
        #expect(first.window.frame.size == second.window.frame.size)
        // Anything that is not a web link opens nothing.
        #expect(setup.state.little.open(URL(string: "file:///etc/hosts")!) == nil)
        #expect(setup.state.little.windows.count == 2)
    }

    @Test func openingInTheHomeSpaceMovesTheLivePage() async throws {
        let setup = try setUp()
        defer { setup.tearDown() }
        let state = setup.state
        var mainWindowShown = 0
        state.openMainWindow = { mainWindowShown += 1 }

        let little = try #require(state.little.open(setup.server.url))
        let webView = little.controller.webView
        try await waitUntil("the page to load", limit: .seconds(15)) { webView.title == "home" && !little.controller.isLoading }
        _ = try await webView.evaluateJavaScript("document.getElementById('note').value = 'half-written'")

        state.little.openInSpace(little)

        let tab = try #require(state.space(setup.work)?.tabs.first)
        #expect(tab.id == little.id)
        #expect(tab.url == setup.server.url)
        #expect(tab.title == "home")
        #expect(state.space(setup.work)?.selectedTabID == tab.id)
        #expect(state.selectedSpaceID == setup.work)
        // The very same web view, with what was typed still in it.
        #expect(state.web.existingController(tab.id)?.webView === webView)
        #expect(try await webView.evaluateJavaScript("document.getElementById('note').value") as? String == "half-written")
        #expect(!little.controller.isLittle)
        #expect(state.little.windows.isEmpty)
        #expect(!little.window.isVisible)
        #expect(mainWindowShown == 1)
        // The page gets the history entry and favicon it skipped while little.
        #expect(state.history(for: setup.work).map(\.url) == [setup.server.url])
        try await waitUntil("the favicon", limit: .seconds(10)) { faviconCount(setup, slug: "work") == 1 }
        // From here on it is an ordinary tab: closing it works as for any tab.
        state.closeTab(tab.id, in: setup.work)
        #expect(state.web.existingController(tab.id) == nil)
    }

    @Test func openingInAnotherSpaceLoadsTheCurrentAddressThere() async throws {
        let setup = try setUp()
        defer { setup.tearDown() }
        let state = setup.state
        let little = try #require(state.little.open(setup.server.url))
        let webView = little.controller.webView
        try await waitUntil("the page to load", limit: .seconds(15)) { webView.title == "home" && !little.controller.isLoading }
        // Go somewhere else first: the address showing is what gets opened, not the first link.
        let two = setup.server.url.appending(path: "two")
        little.controller.load(two)
        try await waitUntil("the second page", limit: .seconds(15)) { webView.title == "two" }

        let chrome = try #require(little.chrome)
        chrome.chooseSpace(setup.personal)
        try await waitUntil("the button to follow the menu") { chrome.openButtonTitle == "Open in Personal" }
        #expect(state.space(setup.personal)?.tabs.isEmpty == true) // nothing happens until the button

        state.little.openInSpace(little)

        let tab = try #require(state.space(setup.personal)?.tabs.first)
        #expect(tab.url == two)
        #expect(tab.id != little.id)
        #expect(state.selectedSpaceID == setup.personal)
        #expect(state.space(setup.personal)?.selectedTabID == tab.id)
        #expect(state.space(setup.work)?.tabs.isEmpty == true)
        #expect(state.history(for: setup.work).isEmpty)
        #expect(state.web.existingController(little.id) == nil) // the old page is gone
        #expect(state.little.windows.isEmpty)
        // The new tab is a new web view, in the other Space's store.
        let controller = try #require(state.web.existingController(tab.id))
        #expect(controller.webView !== webView)
        #expect(controller.spaceID == setup.personal)
    }

    @Test func linksThatWantANewTabStayInTheWindow() async throws {
        let setup = try setUp()
        defer { setup.tearDown() }
        let state = setup.state
        let little = try #require(state.little.open(setup.server.url))
        let webView = little.controller.webView
        try await waitUntil("the page to load", limit: .seconds(15)) { webView.title == "home" && !little.controller.isLoading }

        // What WebKit asks when a target="_blank" link is clicked or a page calls window.open.
        let request = URLRequest(url: setup.server.url.appending(path: "two"))
        let popup = little.controller.webView(webView, createWebViewWith: WKWebViewConfiguration(),
                                              for: FakeNavigationAction(request), windowFeatures: WKWindowFeatures())
        #expect(popup == nil)
        try await waitUntil("the link to load in the same window", limit: .seconds(15)) { webView.title == "two" }
        #expect(state.little.windows.count == 1)
        #expect(state.space(setup.work)?.tabs.isEmpty == true)
    }

    @Test func aLinkThatIsADownloadClosesItsEmptyWindow() async throws {
        let setup = try setUp()
        defer { setup.tearDown() }
        let state = setup.state
        let little = try #require(state.little.open(setup.server.url.appending(path: "file")))
        try await waitUntil("the empty window to close", limit: .seconds(15)) { state.little.windows.isEmpty }
        #expect(!little.window.isVisible)
        #expect(state.web.existingController(little.id) == nil)
        // The download itself goes on without the window and is listed.
        let saved = state.downloads.folder.appending(path: "notes.txt")
        try await waitUntil("the file to be saved", limit: .seconds(15)) {
            (try? String(contentsOf: saved, encoding: .utf8)) == "downloaded"
        }
        #expect(state.downloads.items.map(\.filename) == ["notes.txt"])
        #expect(state.space(setup.work)?.tabs.isEmpty == true)
    }

    @Test func closeCommandClosesTheLittleWindowNotATab() async throws {
        let setup = try setUp()
        defer { setup.tearDown() }
        let state = setup.state
        state.openInNewTab(setup.server.url)
        let tabID = try #require(state.space(setup.work)?.selectedTabID)
        let little = try #require(state.little.open(setup.server.url.appending(path: "two")))

        // Not key: the commands still belong to the main window's tab.
        #expect(state.frontController === state.web.existingController(tabID))
        // Key (what `windowDidBecomeKey` reports; the test window never really takes the keyboard).
        state.little.setKey(little, isKey: true)
        #expect(state.little.keyWindow === little)
        #expect(state.frontController === little.controller)

        state.closeTabCommand() // ⌘W
        #expect(state.little.windows.isEmpty)
        #expect(state.little.keyWindow == nil)
        #expect(state.space(setup.work)?.tab(tabID) != nil, "⌘W on a little window closed a tab")
        #expect(state.frontController === state.web.existingController(tabID))
    }

    @Test func deletingASpaceClosesItsLittleWindows() async throws {
        let setup = try setUp()
        defer { setup.tearDown() }
        let state = setup.state
        let ofWork = try #require(state.little.open(setup.server.url))
        state.selectSpace(setup.personal)
        let ofPersonal = try #require(state.little.open(setup.server.url.appending(path: "two")))
        #expect(ofPersonal.homeSpaceID == setup.personal)
        ofPersonal.chrome?.chooseSpace(setup.work)
        #expect(ofPersonal.chosenSpaceID == setup.work)

        state.deleteSpace(setup.work)

        #expect(state.little.windows.count == 1)
        #expect(state.little.windows.first === ofPersonal)
        #expect(!ofWork.window.isVisible)
        #expect(state.web.existingController(ofWork.id) == nil)
        #expect(state.web.littleControllers(in: setup.work).isEmpty)
        // The other window pointed its button at the deleted Space: back to its own.
        #expect(ofPersonal.chosenSpaceID == setup.personal)
        try await waitUntil("the title bar to follow") { ofPersonal.chrome?.spaceTitles == ["Personal"] }
        #expect(ofPersonal.chrome?.openButtonTitle == "Open in Personal")
    }

    @Test func linksWaitUntilTheAppIsReady() {
        let inbox = LinkInbox()
        var delivered: [String] = []
        // A link that started the app: nobody to hand it to yet.
        inbox.receive([URL(string: "https://example.com/one")!, URL(string: "mailto:x@example.com")!])
        inbox.receive([URL(string: "http://example.com/two")!])
        #expect(delivered.isEmpty)
        inbox.deliver = { delivered.append($0.absoluteString) }
        #expect(delivered == ["https://example.com/one", "http://example.com/two"])
        // Setting it again (the main window appears again) delivers nothing twice.
        inbox.deliver = { delivered.append($0.absoluteString) }
        inbox.receive([URL(string: "https://example.com/three")!])
        #expect(delivered == ["https://example.com/one", "http://example.com/two", "https://example.com/three"])
    }

    @Test func theOpenURLEventReachesTheInbox() {
        let delegate = AppDelegate()
        var delivered: [URL] = []
        delegate.links.deliver = { delivered.append($0) }
        // The Apple event macOS sends the default browser ("GURL").
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kInternetEventClass), eventID: AEEventID(kAEGetURL),
                                           targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID),
                                           transactionID: AETransactionID(kAnyTransactionID))
        event.setParam(NSAppleEventDescriptor(string: "https://example.com/from-slack"), forKeyword: AEKeyword(keyDirectObject))
        delegate.handleGetURL(event, withReplyEvent: NSAppleEventDescriptor.null())
        delegate.application(NSApplication.shared, open: [URL(string: "https://example.com/other")!])
        #expect(delivered.map(\.absoluteString) == ["https://example.com/from-slack", "https://example.com/other"])
    }
}
}

/// A navigation action with a request, for calling the "new window" delegate method directly.
private final class FakeNavigationAction: WKNavigationAction {
    private let fakeRequest: URLRequest
    init(_ request: URLRequest) { fakeRequest = request }
    override var request: URLRequest { fakeRequest }
}

/// A local site: "/" (title "home", a text field, a favicon), "/two" (title "two") and "/file"
/// (an attachment). Run with the system Python, as the other fixture servers are.
private struct LittleFixtureServer {
    let process: Process
    let url: URL

    static func start() throws -> LittleFixtureServer {
        let script = ##"""
        import base64, http.server, os, threading, time
        PARENT = os.getppid()
        def watch():
            while os.getppid() == PARENT: time.sleep(0.2)
            os._exit(0)
        threading.Thread(target=watch, daemon=True).start()
        ICON = base64.b64decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")
        class H(http.server.BaseHTTPRequestHandler):
            def reply(self, status, ctype, body, extra=None):
                self.send_response(status)
                self.send_header("Content-Type", ctype)
                self.send_header("Content-Length", str(len(body)))
                for k, v in (extra or {}).items(): self.send_header(k, v)
                self.end_headers()
                self.wfile.write(body)
            def do_GET(self):
                if self.path == "/": self.reply(200, "text/html", b'<!doctype html><title>home</title><link rel="icon" href="/favicon.png"><input id="note"><a id="blank" target="_blank" href="/two">two</a>')
                elif self.path == "/two": self.reply(200, "text/html", b"<!doctype html><title>two</title><p>second page</p>")
                elif self.path == "/favicon.png": self.reply(200, "image/png", ICON)
                elif self.path == "/file": self.reply(200, "text/plain", b"downloaded", {"Content-Disposition": 'attachment; filename="notes.txt"'})
                else: self.reply(404, "text/plain", b"not found")
            def log_message(self, *a): pass
        s = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
        print(s.server_address[1], flush=True)
        s.serve_forever()
        """##
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", script]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        var line = ""
        while !line.hasSuffix("\n") {
            let data = pipe.fileHandleForReading.availableData
            if data.isEmpty { break }
            line += String(decoding: data, as: UTF8.self)
        }
        let port = Int(line.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        return LittleFixtureServer(process: process, url: URL(string: "http://127.0.0.1:\(port)/")!)
    }

    func stop() { process.terminate() }
}
