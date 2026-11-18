import AppKit
import Foundation
import Testing
@testable import Singularity
import SingularityCore

extension AppTests {
/// More than one browser window, through the real `AppState` and without any NSWindow: the records,
/// the swap when another window comes forward, and the one-place rule. No test here makes a window,
/// starts a shell or loads a page from the network (the tabs are `about:blank`).
@MainActor
@Suite(.serialized) struct MultiWindowTests {
    @MainActor struct Fixture {
        let root: URL
        let state: AppState
        let work: UUID
        let home: UUID
        /// Work's tabs A…D.
        let t: [UUID]
        var first: UUID { state.windows[0].id }
    }

    /// Space "Work" with blank pages A…D (A selected), an empty Space "Home"; one window, on Work.
    func make(stateFile: AppStateFile? = nil, root existing: URL? = nil) throws -> Fixture {
        MainRunLoopGuard.start
        let root = existing ?? TestAppState.makeRoot()
        let store = SpaceStore(paths: Paths(root: root))
        var work = Space(name: "Work", slug: "work", colorHex: "#5E81F4")
        var home = Space(name: "Home", slug: "home", colorHex: "#E5534B")
        if existing == nil {
            for letter in ["A", "B", "C", "D"] {
                work.append(.web(URL(string: "about:blank")!, title: letter))
            }
            work.selectedTabID = work.tabs[0].id
            try store.save(work)
            try store.save(home)
            try store.save(stateFile ?? AppStateFile(spaceOrder: [work.id, home.id], selectedSpaceID: work.id))
        } else {
            let loaded = store.load().spaces
            work = loaded.first { $0.slug == "work" }!
            home = loaded.first { $0.slug == "home" }!
        }
        let state = TestAppState.make(root: root)
        state.terminalHandleOverride = { _ in nil }
        state.inbox.appIsActive = { false }
        state.inbox.windowIsKey = { false }
        return Fixture(root: root, state: state, work: work.id, home: home.id, t: work.tabs.map(\.id))
    }

    func done(_ f: Fixture) {
        TestAppState.shutDown(f.state)
        try? FileManager.default.removeItem(at: f.root)
    }

    /// A second window, made front, with `tab` selected in Work.
    func secondWindow(_ f: Fixture, showing tab: UUID) -> UUID {
        let id = f.state.addWindow()
        f.state.activateWindow(id)
        f.state.selectTab(tab)
        return id
    }

    @Test func oneWindowFromOldStateFile() throws {
        let f = try make()
        defer { done(f) }
        #expect(f.state.windows.count == 1)
        #expect(f.state.frontWindowID == f.first)
        #expect(f.state.selectedSpaceID == f.work)
        #expect(f.state.shownTab(in: f.first)?.id == f.t[0])
    }

    @Test func newWindowShowsFreeTab() throws {
        let f = try make()
        defer { done(f) }
        let second = f.state.addWindow()
        // The Space's last tab (A) is on screen in the first window: the new one shows the home.
        #expect(f.state.shownSpace(in: second)?.id == f.work)
        #expect(f.state.shownTabID(in: second, space: f.state.space(f.work)!) == nil)
        // The first window is still the front one until the new window becomes key.
        #expect(f.state.frontWindowID == f.first)
    }

    @Test func swapKeepsEachWindowsSelection() throws {
        let f = try make()
        defer { done(f) }
        let second = secondWindow(f, showing: f.t[1])
        #expect(f.state.selectedTab?.id == f.t[1])
        f.state.activateWindow(f.first)
        #expect(f.state.selectedTab?.id == f.t[0])
        #expect(f.state.shownTab(in: second)?.id == f.t[1])
        f.state.activateWindow(second)
        #expect(f.state.selectedTab?.id == f.t[1])
        #expect(f.state.shownTab(in: f.first)?.id == f.t[0])
    }

    @Test func selectingTabShownElsewhereMovesOtherWindow() throws {
        let f = try make()
        defer { done(f) }
        let second = secondWindow(f, showing: f.t[1])
        f.state.activateWindow(f.first)
        // A click on B in the first window brings B here; the second window shows its neighbour.
        f.state.selectTab(f.t[1])
        #expect(f.state.selectedTab?.id == f.t[1])
        #expect(f.state.shownTab(in: second)?.id == f.t[2])
    }

    @Test func switchingSpaceDoesNotSteal() throws {
        let f = try make()
        defer { done(f) }
        let second = secondWindow(f, showing: f.t[1])
        // The first window goes to Home; then the second window shows A (the first's Work tab).
        f.state.activateWindow(f.first)
        f.state.selectSpace(f.home)
        f.state.activateWindow(second)
        f.state.selectTab(f.t[0])
        f.state.activateWindow(f.first)
        // Back to Work in the first window: A is on screen in the second, so it gets B instead.
        f.state.selectSpace(f.work)
        #expect(f.state.selectedTab?.id == f.t[1])
        #expect(f.state.shownTab(in: second)?.id == f.t[0])
    }

    @Test func closingTabInFrontFixesBackgroundWindow() throws {
        let f = try make()
        defer { done(f) }
        let second = secondWindow(f, showing: f.t[2])
        f.state.activateWindow(f.first)
        f.state.closeTab(f.t[2], in: f.work, confirmIfBusy: false)
        let shown = f.state.shownTab(in: second)?.id
        #expect(shown != nil && shown != f.t[0] && shown != f.t[2])
    }

    @Test func deletingSpaceMovesBackgroundWindow() throws {
        let f = try make()
        defer { done(f) }
        let second = f.state.addWindow()
        f.state.activateWindow(second)
        f.state.selectSpace(f.home)
        f.state.activateWindow(f.first)
        f.state.deleteSpace(f.home)
        #expect(f.state.shownSpace(in: second)?.id == f.work)
        #expect(f.state.shownTab(in: second)?.id != f.t[0])
    }

    /// An NSWindow for a record, never shown (registered as if SwiftUI had made it).
    func fakeWindow(_ f: Fixture, _ id: UUID) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: 400, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        f.state.registerWindow(window, for: id)
        return window
    }

    @Test func closingFrontWindowActivatesNext() throws {
        let f = try make()
        defer { done(f) }
        let second = secondWindow(f, showing: f.t[1])
        let w1 = fakeWindow(f, f.first), w2 = fakeWindow(f, second)
        defer { _ = (w1, w2) }
        f.state.nsWindows[second] = nil // closed
        f.state.windowClosed(second)
        #expect(f.state.windows.count == 1)
        #expect(f.state.frontWindowID == f.first)
        #expect(f.state.selectedTab?.id == f.t[0])
        // Its tab stays in the Space.
        #expect(f.state.space(f.work)?.tab(f.t[1]) != nil)
    }

    @Test func selectionSurvivesRelaunchWithoutWindowChange() throws {
        let f = try make()
        // A tab selected after the last window change: space.json has it, state.json doesn't.
        f.state.flushSaves()
        f.state.selectTab(f.t[2])
        TestAppState.shutDown(f.state)
        defer { try? FileManager.default.removeItem(at: f.root) }
        let again = try make(root: f.root)
        defer { TestAppState.shutDown(again.state) }
        #expect(again.state.selectedTab?.id == f.t[2])
    }

    @Test func closingTabDoesNotTakeAnotherWindowsTab() throws {
        let f = try make()
        defer { done(f) }
        // The second window shows B, A's neighbour. Closing A in the first must not take B.
        let second = secondWindow(f, showing: f.t[1])
        f.state.activateWindow(f.first)
        f.state.closeTab(f.t[0], in: f.work, confirmIfBusy: false)
        #expect(f.state.shownTab(in: second)?.id == f.t[1])
        #expect(f.state.selectedTab?.id != f.t[1])
    }

    @Test func homeStaysHomeAfterSwap() throws {
        let f = try make()
        defer { done(f) }
        // The new window shows Work's home (A is in the first window).
        let second = f.state.addWindow()
        f.state.activateWindow(second)
        #expect(f.state.selectedTab == nil)
        f.state.activateWindow(f.first)
        #expect(f.state.shownTab(in: second) == nil)
        f.state.activateWindow(second)
        #expect(f.state.selectedTab == nil)
        #expect(f.state.shownTab(in: f.first)?.id == f.t[0])
    }

    @Test func dropOnAnotherWindowsPaneDoesNothing() throws {
        let f = try make()
        defer { done(f) }
        let second = secondWindow(f, showing: f.t[1])
        f.state.activateWindow(f.first)
        f.state.handleTabDrop(f.t[2], onto: f.t[1], zone: .center)
        #expect(f.state.shownTab(in: second)?.id == f.t[1])
        #expect(f.state.selectedTab?.id == f.t[0])
    }

    @Test func newWindowWithNoneOpenReopensTheWaitingOne() throws {
        let f = try make()
        defer { done(f) }
        var opened: [UUID] = []
        f.state.openBrowserWindow = { opened.append($0) }
        // The last browser window was closed while something else kept the app running.
        f.state.windowClosed(f.first)
        f.state.newWindow()
        #expect(opened == [f.first])
        #expect(f.state.windows.count == 1)
    }

    @Test func closingLastWindowKeepsRecord() throws {
        let f = try make()
        defer { done(f) }
        f.state.windowClosed(f.first)
        #expect(f.state.windows.count == 1)
        #expect(f.state.frontWindowID == f.first)
    }

    @Test func sidebarHiddenIsPerWindow() throws {
        let f = try make()
        defer { done(f) }
        let second = secondWindow(f, showing: f.t[1])
        f.state.toggleSidebar()
        #expect(f.state.sidebarHidden(in: second))
        #expect(!f.state.sidebarHidden(in: f.first))
        #expect(f.state.settings.sidebarHidden)
        f.state.activateWindow(f.first)
        // Settings follow the front window (an older version opens like it).
        #expect(!f.state.settings.sidebarHidden)
        #expect(f.state.sidebarHidden(in: second))
    }

    @Test func openFromArtifactGoesToOriginWindow() throws {
        let f = try make()
        defer { done(f) }
        let second = secondWindow(f, showing: f.t[1])
        f.state.activateWindow(f.first)
        f.state.openInNewTab(URL(string: "about:blank#new")!, spaceID: f.work, target: .origin(f.t[1]))
        let added = try #require(f.state.space(f.work)?.tabs.last)
        #expect(f.state.shownTab(in: second)?.id == added.id)
        #expect(f.state.selectedTab?.id == f.t[0])
    }

    @Test func openFromArtifactWithoutWindowSelectsNothing() throws {
        let f = try make()
        defer { done(f) }
        let second = secondWindow(f, showing: f.t[1])
        f.state.activateWindow(f.first)
        // D is on screen nowhere.
        f.state.openInNewTab(URL(string: "about:blank#new")!, spaceID: f.work, target: .origin(f.t[3]))
        #expect(f.state.space(f.work)?.tabs.count == 5)
        #expect(f.state.selectedTab?.id == f.t[0])
        #expect(f.state.shownTab(in: second)?.id == f.t[1])
    }

    @Test func paletteNewTabStillSelects() throws {
        let f = try make()
        defer { done(f) }
        _ = secondWindow(f, showing: f.t[1])
        f.state.openInNewTab(URL(string: "about:blank#new")!)
        #expect(f.state.selectedTab?.id == f.state.space(f.work)?.tabs.last?.id)
    }

    @Test func clickInBackgroundWindowSelectsThere() throws {
        let f = try make()
        defer { done(f) }
        let second = secondWindow(f, showing: f.t[1])
        f.state.activateWindow(f.first)
        // A click in the second window's pane (B): that window comes forward; the first keeps A.
        f.state.focusPane(f.t[1])
        #expect(f.state.frontWindowID == second)
        #expect(f.state.shownTab(in: f.first)?.id == f.t[0])
        #expect(f.state.selectedTab?.id == f.t[1])
    }

    @Test func listTabsFlagsCoverEveryWindow() throws {
        let f = try make()
        defer { done(f) }
        _ = secondWindow(f, showing: f.t[1])
        f.state.activateWindow(f.first)
        #expect(f.state.isTabShownInAnyWindow(f.t[0]))
        #expect(f.state.isTabShownInAnyWindow(f.t[1]))
        #expect(!f.state.isTabShownInAnyWindow(f.t[2]))
        #expect(f.state.isTabSelectedInAnyWindow(f.t[1], spaceID: f.work))
    }

    @Test func windowsSurviveSaveAndLoad() throws {
        let f = try make()
        let second = secondWindow(f, showing: f.t[1])
        f.state.toggleSidebar()
        f.state.windowFrameChanged(second, frame: NSRect(x: 40, y: 50, width: 900, height: 600))
        f.state.activateWindow(f.first)
        TestAppState.shutDown(f.state)
        defer { try? FileManager.default.removeItem(at: f.root) }

        let again = try make(root: f.root)
        defer { TestAppState.shutDown(again.state) }
        #expect(again.state.windows.map(\.id) == [f.first, second])
        #expect(again.state.frontWindowID == f.first)
        #expect(again.state.selectedTab?.id == f.t[0])
        #expect(again.state.shownTab(in: second)?.id == f.t[1])
        #expect(again.state.sidebarHidden(in: second))
        #expect(again.state.windows[1].frame == WindowFrame(x: 40, y: 50, width: 900, height: 600))
    }

    @Test func claimingRecords() throws {
        let f = try make()
        defer { done(f) }
        let second = f.state.addWindow()
        // SwiftUI's first window (no value) takes the first record; the rest are opened by value.
        #expect(f.state.claimWindow(nil) == f.first)
        #expect(f.state.unclaimedWindowIDs() == [second])
        #expect(f.state.claimWindow(second) == second)
        // A window SwiftUI restored by itself, when every record is shown, gets none (it closes).
        #expect(f.state.claimWindow(UUID()) == nil)
        #expect(f.state.claimWindow(f.first) == nil)
    }
}
}
