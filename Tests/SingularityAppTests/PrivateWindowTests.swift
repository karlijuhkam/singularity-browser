import AppKit
import Foundation
import Testing
import WebKit
@testable import Singularity
import SingularityCore

extension AppTests {
/// Private windows: pages with an in-memory data store that leave nothing behind. A real
/// `AppState`, real windows (far off screen, never key) and the little windows' fixture site.
@MainActor
@Suite(.serialized) struct PrivateWindowTests {
    private struct Setup {
        let root: URL
        let state: AppState
        let server: LittleFixtureServer
        let work: UUID

        @MainActor func tearDown() {
            for entry in state.privateWindows.windows { state.privateWindows.close(entry) }
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
        try store.save(work)
        try store.save(AppStateFile(spaceOrder: [work.id], selectedSpaceID: work.id))
        let state = TestAppState.make(root: root)
        state.privateWindows.staysOffScreen = true
        state.downloads.folder = root.appending(path: "downloads", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: state.downloads.folder, withIntermediateDirectories: true)
        return Setup(root: root, state: state, server: try LittleFixtureServer.start(), work: work.id)
    }

    private func modified(_ file: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date
    }

    private func loaded(_ entry: PrivateWindow, title: String) async throws {
        try await waitUntil("the page to load", limit: .seconds(15)) {
            entry.controller.webView.title == title && !entry.controller.isLoading
        }
    }

    @Test func aPageLeavesNothingBehind() async throws {
        let setup = try setUp()
        defer { setup.tearDown() }
        let state = setup.state
        state.flushSaves()
        let spaceFile = state.paths.spaceFile("work")
        let savedAt = modified(spaceFile)

        let entry = state.privateWindows.open(setup.server.url)
        try await loaded(entry, title: "home")
        // Time for what must *not* happen (a history entry, a favicon fetch, a save) to happen.
        try await Task.sleep(for: .milliseconds(700))
        state.flushSaves()

        #expect(entry.controller.isPrivate)
        #expect(!entry.controller.isLittle)
        #expect(state.web.existingController(entry.controller.tabID) == nil, "a private page is in the registry")
        #expect(state.space(entry.controller.spaceID) == nil)
        #expect(state.space(setup.work)?.tabs.isEmpty == true)
        #expect(state.history(for: setup.work).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: state.paths.historyFile("work").path))
        let favicons = state.paths.faviconsDirectory("work")
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: favicons.path)) ?? []).isEmpty)
        #expect(modified(spaceFile) == savedAt, "space.json was rewritten for a private page")

        let store = try #require(state.privateWindows.dataStore)
        #expect(!store.isPersistent)
        #expect(entry.controller.webView.configuration.websiteDataStore === store)
        // Nothing of ours is in the page: no page agent, no plugin scripts.
        #expect(entry.controller.webView.configuration.userContentController.userScripts.isEmpty)
        #expect(entry.controller.webView.configuration.webExtensionController == nil)

        // The title bar.
        let chrome = try #require(entry.chrome)
        try await waitUntil("the address field to follow the page") { chrome.addressText == setup.server.url.absoluteString }
        #expect(chrome.markTitle == "Private")
        #expect(!entry.window.isRestorable)
        #expect(entry.window.title == "home — Private")
    }

    @Test func cookiesStayInThePrivateStore() async throws {
        let setup = try setUp()
        defer { setup.tearDown() }
        let state = setup.state
        let entry = state.privateWindows.open(setup.server.url)
        try await loaded(entry, title: "home")
        _ = try await entry.controller.webView.evaluateJavaScript("document.cookie = 'secret=1; path=/'; document.cookie")

        // The Space's own tab on the same site sees none of it.
        state.openInNewTab(setup.server.url)
        let space = try #require(state.space(setup.work))
        let tab = try #require(space.tabs.first)
        let controller = state.web.controller(for: tab, in: space)
        try await waitUntil("the tab to load", limit: .seconds(15)) { controller.webView.title == "home" && !controller.isLoading }
        let spaceCookies = try await controller.webView.evaluateJavaScript("document.cookie") as? String
        #expect(spaceCookies == "")

        // A second private window shares the first one's.
        let second = state.privateWindows.open(setup.server.url.appending(path: "two"))
        try await loaded(second, title: "two")
        let shared = try await second.controller.webView.evaluateJavaScript("document.cookie") as? String
        #expect(shared == "secret=1")
    }

    @Test func theStoreGoesWithTheLastWindow() async throws {
        let setup = try setUp()
        defer { setup.tearDown() }
        let windows = setup.state.privateWindows
        let first = windows.open()
        let second = windows.open()
        let store = try #require(windows.dataStore)
        #expect(second.controller.webView.configuration.websiteDataStore === store)
        #expect(first.showsNote)

        windows.close(first)
        #expect(windows.dataStore === store, "the store went while a private window was still open")
        windows.close(second)
        #expect(windows.dataStore == nil)

        let third = windows.open()
        let fresh = try #require(windows.dataStore)
        #expect(fresh !== store)
        #expect(third.controller.webView.configuration.websiteDataStore === fresh)
    }

    @Test func popUpsGetAPrivateWindowOfTheirOwn() async throws {
        let setup = try setUp()
        defer { setup.tearDown() }
        let state = setup.state
        let entry = state.privateWindows.open(setup.server.url)
        let webView = entry.controller.webView
        try await loaded(entry, title: "home")

        // What WebKit asks when a target="_blank" link is clicked or a page calls window.open.
        let configuration = try #require(webView.configuration.copy() as? WKWebViewConfiguration)
        let request = URLRequest(url: setup.server.url.appending(path: "two"))
        let popup = entry.controller.webView(webView, createWebViewWith: configuration,
                                             for: FakeNavigationAction(request), windowFeatures: WKWindowFeatures())
        let popupView = try #require(popup)
        #expect(state.privateWindows.windows.count == 2)
        let second = try #require(state.privateWindows.windows.last)
        #expect(second.controller.webView === popupView)
        #expect(second.controller.isPrivate)
        #expect(!second.showsNote)
        #expect(popupView.configuration.websiteDataStore === state.privateWindows.dataStore)
        #expect(state.space(setup.work)?.tabs.isEmpty == true)

        // Not for addresses that aren't web pages.
        let file = URLRequest(url: URL(string: "file:///etc/hosts")!)
        #expect(entry.controller.webView(webView, createWebViewWith: configuration, for: FakeNavigationAction(file),
                                         windowFeatures: WKWindowFeatures()) == nil)
        #expect(state.privateWindows.windows.count == 2)

        // window.close() in the pop-up closes its window only.
        second.controller.webViewDidClose(popupView)
        #expect(state.privateWindows.windows.map(\.id) == [entry.id])
    }

    @Test func theAddressFieldLoadsWhatIsTyped() async throws {
        let setup = try setUp()
        defer { setup.tearDown() }
        let entry = setup.state.privateWindows.open()
        let chrome = try #require(entry.chrome)
        chrome.load(typed: "127.0.0.1:\(setup.server.url.port!)/two")
        try await loaded(entry, title: "two")
        #expect(entry.controller.webView.url == setup.server.url.appending(path: "two"))
    }

    @Test func menuCommandsActOnTheWindowInFront() async throws {
        let setup = try setUp()
        defer { setup.tearDown() }
        let state = setup.state
        state.openInNewTab(setup.server.url)
        let tabID = try #require(state.space(setup.work)?.selectedTabID)
        let entry = state.privateWindows.open(setup.server.url.appending(path: "two"))

        #expect(state.frontController === state.web.existingController(tabID))
        state.privateWindows.setFront(entry, isFront: true)
        #expect(state.frontController === entry.controller)

        state.closeTabCommand() // ⌘W
        #expect(state.privateWindows.windows.isEmpty)
        #expect(state.privateWindows.frontWindow == nil)
        #expect(state.space(setup.work)?.tab(tabID) != nil, "⌘W on a private window closed a tab")
    }

    /// Not a check: with SG_PRIVATE_SNAPSHOT=<folder> it writes pictures of an empty private window
    /// and one with a page (title bar included), to look at without putting a window on screen.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SG_PRIVATE_SNAPSHOT"] != nil))
    func snapshot() async throws {
        let setup = try setUp()
        defer { setup.tearDown() }
        let folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SG_PRIVATE_SNAPSHOT"]!)
        let empty = setup.state.privateWindows.open()
        let page = setup.state.privateWindows.open(setup.server.url.appending(path: "two"))
        try await loaded(page, title: "two")
        try await Task.sleep(for: .milliseconds(500))
        for (entry, name) in [(empty, "empty.png"), (page, "page.png")] {
            let frame = try #require(entry.window.contentView?.superview)
            let bitmap = try #require(frame.bitmapImageRepForCachingDisplay(in: frame.bounds))
            frame.cacheDisplay(in: frame.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: folder.appending(path: name))
        }
    }

    @Test func aClosedWindowIsFreedWithItsPage() async throws {
        let setup = try setUp()
        defer { setup.tearDown() }
        let state = setup.state
        weak var closedPage: WKWebView?
        weak var closedWindow: PrivateWindow?
        do {
            let entry = state.privateWindows.open(setup.server.url)
            (closedPage, closedWindow) = (entry.controller.webView, entry)
            try await loaded(entry, title: "home")
            state.privateWindows.close(entry)
        }
        try await waitUntil("the closed window and its page to be freed", limit: .seconds(10)) {
            closedPage == nil && closedWindow == nil
        }
    }
}
}
