import Foundation
import Testing
import WebKit
@testable import Singularity
import SingularityCore

extension AppTests {
/// The app's inbox: terminal signals make entries unless the owner is looking at the tab, and
/// going to the tab (or closing it) takes them away again.
@MainActor
@Suite(.serialized) struct InboxCenterTests {
    /// What the callbacks saw.
    @MainActor final class Recorder {
        var arrivals: [InboxEntry] = []
        var changes = 0
    }

    /// Two Spaces, "one" and "two". "two" holds the agent's tab, selected within that Space.
    ///
    /// The agent's tab is a web tab on about:blank standing in for a terminal: the inbox only sees
    /// ids, and a real terminal tab would start the owner's login shell when it comes on screen.
    @MainActor struct Fixture {
        let root: URL
        let state: AppState
        let one: Space
        let two: Space
        let tab: BrowserTab
        let recorder: Recorder
        var center: InboxCenter { state.inbox }
    }

    private func makeFixture(selecting selected: String = "one") throws -> Fixture {
        MainRunLoopGuard.start
        let root = TestAppState.makeRoot()
        let store = SpaceStore(paths: Paths(root: root))
        let blank = URL(string: "about:blank")!
        let oneTab = BrowserTab.web(blank, title: "page")
        let tab = BrowserTab.web(blank, title: "claude")
        let one = Space(name: "one", slug: "one", colorHex: "#5E81F4", tabs: [oneTab], selectedTabID: oneTab.id)
        let two = Space(name: "two", slug: "two", colorHex: "#F45E81", tabs: [tab], selectedTabID: tab.id)
        try store.save(one)
        try store.save(two)
        try store.save(AppStateFile(spaceOrder: [one.id, two.id], selectedSpaceID: selected == "two" ? two.id : one.id))

        let state = TestAppState.make(root: root)
        let recorder = Recorder()
        state.inbox.appIsActive = { true }
        state.inbox.windowIsKey = { true }
        state.inbox.now = { Date(timeIntervalSince1970: 1_000) }
        state.inbox.onArrival = { recorder.arrivals.append($0) }
        state.inbox.onChange = { recorder.changes += 1 }
        return Fixture(root: root, state: state, one: one, two: two, tab: tab, recorder: recorder)
    }

    private func tearDown(_ f: Fixture) {
        TestAppState.shutDown(f.state)
        try? FileManager.default.removeItem(at: f.root)
    }

    /// Showing the agent's tab made a web view with Space two's (persistent) website data store:
    /// remove it again, as deleting a Space does (WebKit refuses while the view is still alive).
    private func forgetWebsiteData(_ f: Fixture) async {
        f.state.web.removeControllers(for: [f.tab.id])
        try? await Task.sleep(for: .seconds(1))
        try? await WKWebsiteDataStore.remove(forIdentifier: f.two.id)
    }

    private let blocked = TerminalSignal.status([
        StatusRecord(id: "", state: .blocked, kind: .question, app: "claude-code", message: "Which database?"),
    ])

    private func sendBlocked(_ f: Fixture) {
        f.center.terminalSignal(blocked, tabID: f.tab.id, spaceID: f.two.id, foregroundProgram: "claude")
    }

    @Test func signalFromAnotherSpaceCreatesAnEntryAndAnnounces() throws {
        let f = try makeFixture()
        defer { tearDown(f) }
        sendBlocked(f)
        #expect(f.center.inbox.visible.count == 1)
        #expect(f.recorder.arrivals.count == 1)
        let entry = try #require(f.center.inbox.visible.first)
        #expect(entry.kind == .waiting(.question))
        #expect(entry.agent == "Claude Code")
        #expect(entry.spaceID == f.two.id && entry.tabID == f.tab.id)
        #expect(entry.message == "Which database?")
        #expect(f.recorder.changes == 1)

        // The same state again: updated in place, not announced a second time.
        sendBlocked(f)
        #expect(f.center.inbox.visible.count == 1)
        #expect(f.recorder.arrivals.count == 1)
    }

    @Test func signalFromTheTabOnScreenDoesNothing() throws {
        let f = try makeFixture(selecting: "two")
        defer { tearDown(f) }
        #expect(f.state.isTabOnScreen(f.tab.id))
        sendBlocked(f)
        #expect(f.center.inbox.visible.isEmpty)
        #expect(f.recorder.arrivals.isEmpty)
        #expect(f.recorder.changes == 0)
    }

    @Test func inactiveAppStillCreatesAnEntryForTheTabOnScreen() throws {
        let f = try makeFixture(selecting: "two")
        defer { tearDown(f) }
        f.center.appIsActive = { false }
        sendBlocked(f)
        #expect(f.center.inbox.visible.count == 1)
        #expect(f.recorder.arrivals.count == 1)
    }

    @Test func otherWindowInFrontStillCreatesAnEntry() throws {
        let f = try makeFixture(selecting: "two")
        defer { tearDown(f) }
        f.center.windowIsKey = { false }
        sendBlocked(f)
        #expect(f.center.inbox.visible.count == 1)
    }

    @Test func selectingTheTabRemovesItsEntry() async throws {
        let f = try makeFixture()
        defer { tearDown(f) }
        sendBlocked(f)
        #expect(f.center.inbox.visible.count == 1)
        f.state.showTab(f.tab.id, in: f.two.id)
        #expect(f.center.inbox.visible.isEmpty)
        #expect(f.recorder.changes == 2)
        await forgetWebsiteData(f)
    }

    @Test func selectingAnotherTabKeepsTheEntry() throws {
        let f = try makeFixture()
        defer { tearDown(f) }
        sendBlocked(f)
        // Space one is already selected: selecting its tab again brings only that tab on screen.
        f.state.selectTab(f.one.tabs[0].id)
        f.state.selectSpace(f.one.id)
        #expect(f.center.inbox.visible.count == 1)
    }

    @Test func closingTheTabRemovesItsEntry() throws {
        let f = try makeFixture()
        defer { tearDown(f) }
        sendBlocked(f)
        f.state.closeTab(f.tab.id, in: f.two.id, confirmIfBusy: false)
        #expect(f.center.inbox.visible.isEmpty)
        #expect(f.center.inbox.workingTabs.isEmpty)
    }

    @Test func goingToTheTabWithNothingWaitingChangesNothing() throws {
        let f = try makeFixture()
        defer { tearDown(f) }
        f.center.wentToTerminal(f.tab.id)
        #expect(f.recorder.changes == 0)
        sendBlocked(f)
        f.center.wentToTerminal(f.one.tabs[0].id)
        #expect(f.recorder.changes == 1)
        #expect(f.center.inbox.visible.count == 1)
    }

    @Test func goToShowsTheTabAndClosesThePanel() async throws {
        let f = try makeFixture()
        defer { tearDown(f) }
        sendBlocked(f)
        let entry = try #require(f.center.inbox.visible.first)
        f.center.isPanelShown = true
        f.center.goTo(entry)
        #expect(f.state.selectedSpaceID == f.two.id)
        #expect(f.state.selectedTab?.id == f.tab.id)
        #expect(f.center.inbox.visible.isEmpty)
        #expect(!f.center.isPanelShown)
        await forgetWebsiteData(f)
    }

    @Test func programExitRemovesTheEntry() throws {
        let f = try makeFixture()
        defer { tearDown(f) }
        sendBlocked(f)
        f.center.terminalSignal(.programExited, tabID: f.tab.id, spaceID: f.two.id, foregroundProgram: nil)
        #expect(f.center.inbox.visible.isEmpty)
        #expect(f.recorder.arrivals.count == 1)
    }

    @Test func dismissRemovesOneEntry() throws {
        let f = try makeFixture()
        defer { tearDown(f) }
        f.center.terminalSignal(.status([StatusRecord(id: "", state: .done, kind: nil, app: "claude-code", message: "All set")]),
                                tabID: f.tab.id, spaceID: f.two.id, foregroundProgram: "claude")
        let entry = try #require(f.center.inbox.visible.first)
        #expect(entry.kind == .done)
        f.center.dismiss(entry.id)
        #expect(f.center.inbox.visible.isEmpty)
        #expect(f.recorder.changes == 2)
    }
}
}
