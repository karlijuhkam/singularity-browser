import AppKit
import Foundation
import Testing
import WebKit
@testable import Singularity
import SingularityCore

extension AppTests {
/// A tab's stored title belongs to the page it shows: moving to a page without a title (or a failed
/// load) clears the previous page's, without making a normal load flash the address; a restored
/// tab keeps its saved title; and while a load of another page is under way the title is not
/// "current" (agents and plugins are not given it with the new address).
@MainActor
@Suite(.serialized) struct PageTitleTests {
    @MainActor final class Rig {
        let root = TestAppState.makeRoot()
        let server: TitleFixtureServer
        let state: AppState
        let spaceID: UUID
        let tabID: UUID

        init(savedTitle: String = "", path: String = "/titled?t=Alpha") throws {
            MainRunLoopGuard.start
            server = try TitleFixtureServer.start()
            let store = SpaceStore(paths: Paths(root: root))
            var space = Space(name: "Work", slug: "work", colorHex: "#5E81F4")
            let tab = BrowserTab.web(server.url(path), title: savedTitle)
            space.append(tab)
            space.selectedTabID = tab.id
            try store.save(space)
            try store.save(AppStateFile(spaceOrder: [space.id], selectedSpaceID: space.id))
            state = TestAppState.make(root: root)
            spaceID = space.id
            tabID = tab.id
        }

        var tab: BrowserTab? { state.space(spaceID)?.tab(tabID) }

        func controller() async throws -> WebTabController {
            let controller = try #require(await state.liveWebController(tabID: tabID, spaceID: spaceID))
            try await waitUntil("the first page", limit: .seconds(10)) { !controller.webView.isLoading && controller.webView.url != nil }
            return controller
        }

        func tearDown() {
            TestAppState.shutDown(state)
            server.stop()
            try? FileManager.default.removeItem(at: root)
        }
    }

    @Test(.timeLimit(.minutes(1))) func movingToAnUntitledPageClearsTheOldTitle() async throws {
        let rig = try Rig()
        defer { rig.tearDown() }
        let controller = try await rig.controller()
        try await waitUntil("Alpha") { rig.tab?.title == "Alpha" }

        controller.load(rig.server.url("/untitled", host: "localhost"))
        try await waitUntil("the old title to go", limit: .seconds(10)) { rig.tab?.title == "" }
        #expect(rig.tab?.displayTitle == "localhost")
        #expect(controller.titleIsCurrent)

        // A failed load of another page: its error page is no title either.
        controller.load(rig.server.url("/titled?t=Beta"))
        try await waitUntil("Beta", limit: .seconds(10)) { rig.tab?.title == "Beta" }
        controller.load(URL(string: "http://localhost:1/nothing")!)
        try await waitUntil("the old title to go after the failed load", limit: .seconds(10)) { rig.tab?.title == "" }
        #expect(rig.tab?.displayTitle == "localhost")
    }

    /// From a titled page to another titled page, the sidebar never shows the address in between
    /// (the stored title goes from the old one straight to the new one); and while the new page
    /// loads, the old title is not current.
    @Test(.timeLimit(.minutes(1))) func aNormalLoadDoesNotFlashTheAddress() async throws {
        let rig = try Rig()
        defer { rig.tearDown() }
        let controller = try await rig.controller()
        try await waitUntil("Alpha") { rig.tab?.title == "Alpha" }

        controller.load(rig.server.url("/slow-titled?t=Beta"))
        var seen: [String] = []
        var sawStaleTitleNotCurrent = false
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            let title = rig.tab?.title ?? "?"
            if seen.last != title { seen.append(title) }
            if title == "Alpha", rig.tab?.url?.query() == "t=Beta", !controller.titleIsCurrent { sawStaleTitleNotCurrent = true }
            if title == "Beta", !controller.webView.isLoading { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        // Give a late clear (the grace after the load) a chance to show up.
        try await Task.sleep(for: WebTabController.untitledGrace + .milliseconds(200))
        if seen.last != rig.tab?.title { seen.append(rig.tab?.title ?? "?") }
        #expect(seen == ["Alpha", "Beta"], "titles seen: \(seen)")
        #expect(sawStaleTitleNotCurrent)
        #expect(controller.titleIsCurrent)

        // Moving within the page (pushState) keeps the title current.
        _ = try await controller.webView.evaluateJavaScript("history.pushState({}, '', '/elsewhere'); 1")
        try await waitUntil("the new address") { controller.webView.url?.path() == "/elsewhere" }
        #expect(controller.titleIsCurrent)
        #expect(rig.tab?.title == "Beta")
    }

    /// A restored tab shows its saved title before it is loaded, and keeps it when its own page
    /// (here one without a title) loads.
    @Test(.timeLimit(.minutes(1))) func aRestoredTabKeepsItsSavedTitle() async throws {
        let rig = try Rig(savedTitle: "Saved", path: "/untitled")
        defer { rig.tearDown() }
        #expect(rig.tab?.title == "Saved")
        let controller = try await rig.controller()
        try await Task.sleep(for: WebTabController.untitledGrace + .milliseconds(300))
        #expect(rig.tab?.title == "Saved")
        #expect(controller.titleIsCurrent)
    }
}
}
