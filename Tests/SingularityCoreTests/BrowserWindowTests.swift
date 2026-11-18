import Foundation
import Testing
@testable import SingularityCore

@Suite struct BrowserWindowTests {
    /// A Space with tabs A…E (all open, in that order).
    func makeSpace(_ name: String = "Work") -> (Space, [UUID]) {
        var space = Space(name: name, slug: name.lowercased(), colorHex: "#5E81F4")
        for letter in ["A", "B", "C", "D", "E"] {
            space.append(.web(URL(string: "https://\(letter.lowercased()).test")!, title: letter))
        }
        return (space, space.tabs.map(\.id))
    }

    func window(_ space: UUID?, _ tab: UUID?) -> BrowserWindowState {
        var selected: [UUID: UUID] = [:]
        if let space, let tab { selected[space] = tab }
        return BrowserWindowState(spaceID: space, selectedTabIDs: selected)
    }

    // MARK: - shownTabIDs / freeTab

    @Test func shownTabsIncludeSplitPartners() {
        var (space, t) = makeSpace()
        space.split(t[1], beside: t[0], edge: .right)
        #expect(WindowLayout.shownTabIDs(in: space, selected: t[0]) == [t[0], t[1]])
        #expect(WindowLayout.shownTabIDs(in: space, selected: t[2]) == [t[2]])
        #expect(WindowLayout.shownTabIDs(in: space, selected: nil).isEmpty)
        #expect(WindowLayout.shownTabIDs(in: space, selected: UUID()).isEmpty)
    }

    @Test func freeTabPrefersCurrent() {
        let (space, t) = makeSpace()
        #expect(WindowLayout.freeTab(in: space, preferring: t[2], taken: [t[0]]) == t[2])
    }

    @Test func freeTabSkipsTakenAndSplitPartners() {
        var (space, t) = makeSpace()
        space.split(t[3], beside: t[2], edge: .right)
        // C is taken; the next after it is D, whose split partner C is taken; then E.
        #expect(WindowLayout.freeTab(in: space, preferring: t[2], taken: [t[2]]) == t[4])
        // E taken too: nearest before C is B.
        #expect(WindowLayout.freeTab(in: space, preferring: t[2], taken: [t[2], t[4]]) == t[1])
        // Nothing preferred: the first free one in sidebar order.
        #expect(WindowLayout.freeTab(in: space, preferring: nil, taken: [t[0]]) == t[1])
    }

    @Test func freeTabNilWhenAllTaken() {
        let (space, t) = makeSpace()
        #expect(WindowLayout.freeTab(in: space, preferring: t[0], taken: Set(t)) == nil)
        #expect(WindowLayout.freeTab(in: Space(name: "E", slug: "e", colorHex: "#000000"), preferring: nil, taken: []) == nil)
    }

    // MARK: - reconcile

    @Test func reconcileMovesWindowOffFrontTab() {
        let (space, t) = makeSpace()
        let front = window(space.id, t[1])
        let other = window(space.id, t[1])
        let result = WindowLayout.reconcile([front, other], frontID: front.id, frontSpaceID: space.id,
                                            frontSelected: t[1], spaces: [space])
        #expect(result[1].selectedTabIDs[space.id] == t[2])
    }

    @Test func reconcileKeepsFrontUntouched() {
        let (space, t) = makeSpace()
        // The front's record is stale (the live fields count); it must not be rewritten.
        let front = window(space.id, t[4])
        let other = window(space.id, t[0])
        let result = WindowLayout.reconcile([other, front], frontID: front.id, frontSpaceID: space.id,
                                            frontSelected: t[0], spaces: [space])
        #expect(result[1] == front)
        #expect(result[0].selectedTabIDs[space.id] == t[1])
    }

    @Test func reconcileDeletedSpaceGoesToFirst() {
        let (work, t) = makeSpace()
        let (home, h) = makeSpace("Home")
        let front = window(work.id, t[0])
        let other = window(UUID(), nil)
        let result = WindowLayout.reconcile([front, other], frontID: front.id, frontSpaceID: work.id,
                                            frontSelected: t[0], spaces: [home, work])
        #expect(result[1].spaceID == home.id)
        _ = h
    }

    @Test func reconcileClosedTabPicksNeighbour() {
        var (space, t) = makeSpace()
        let other = window(space.id, t[3])
        space.closeTab(t[3])
        let front = window(space.id, t[0])
        let result = WindowLayout.reconcile([front, other], frontID: front.id, frontSpaceID: space.id,
                                            frontSelected: t[0], spaces: [space])
        // D was gone; no "position" left to keep, so the first free tab in sidebar order.
        #expect(result[1].selectedTabIDs[space.id] == t[1])
    }

    @Test func reconcileTwoBackgroundWindowsDontShare() {
        let (space, t) = makeSpace()
        let front = window(space.id, t[0])
        let a = window(space.id, t[2])
        let b = window(space.id, t[2])
        let result = WindowLayout.reconcile([front, a, b], frontID: front.id, frontSpaceID: space.id,
                                            frontSelected: t[0], spaces: [space])
        #expect(result[1].selectedTabIDs[space.id] == t[2])
        #expect(result[2].selectedTabIDs[space.id] == t[3])
    }

    @Test func reconcileOtherSpaceIsIndependent() {
        let (work, t) = makeSpace()
        let (home, h) = makeSpace("Home")
        let front = window(work.id, t[0])
        let other = window(home.id, h[0])
        let result = WindowLayout.reconcile([front, other], frontID: front.id, frontSpaceID: work.id,
                                            frontSelected: t[0], spaces: [work, home])
        #expect(result[1] == other)
    }

    @Test func reconcileDropsEntriesOfGoneSpacesAndTabs() {
        let (space, t) = makeSpace()
        var other = window(space.id, t[1])
        other.selectedTabIDs[UUID()] = UUID()
        let front = window(space.id, t[0])
        let result = WindowLayout.reconcile([front, other], frontID: front.id, frontSpaceID: space.id,
                                            frontSelected: t[0], spaces: [space])
        #expect(result[1].selectedTabIDs == [space.id: t[1]])
    }

    @Test func reconcileEmptySpaceShowsNothing() {
        let (space, t) = makeSpace()
        let empty = Space(name: "Empty", slug: "empty", colorHex: "#000000")
        let front = window(space.id, t[0])
        let other = window(empty.id, nil)
        let result = WindowLayout.reconcile([front, other], frontID: front.id, frontSpaceID: space.id,
                                            frontSelected: t[0], spaces: [space, empty])
        #expect(result[1] == other)
    }

    // MARK: - state.json

    @Test func appStateFileWithoutWindowsDecodes() throws {
        let id = UUID()
        let json = #"{"spaceOrder":["\#(id.uuidString)"],"selectedSpaceID":"\#(id.uuidString)"}"#
        let file = try JSONDecoder().decode(AppStateFile.self, from: Data(json.utf8))
        #expect(file.windows.isEmpty)
        #expect(file.frontWindowID == nil)
        #expect(file.selectedSpaceID == id)
    }

    @Test func appStateFileRoundTripsWindows() throws {
        let space = UUID(), tab = UUID()
        var w = BrowserWindowState(spaceID: space, selectedTabIDs: [space: tab], sidebarHidden: true)
        w.frame = WindowFrame(x: 10, y: 20, width: 900, height: 700)
        let file = AppStateFile(spaceOrder: [space], selectedSpaceID: space, windows: [w], frontWindowID: w.id)
        let decoded = try JSONDecoder().decode(AppStateFile.self, from: JSONEncoder().encode(file))
        #expect(decoded == file)
    }

    @Test func windowStateToleratesMissingFields() throws {
        let id = UUID()
        let decoded = try JSONDecoder().decode(BrowserWindowState.self, from: Data(#"{"id":"\#(id.uuidString)"}"#.utf8))
        #expect(decoded.id == id)
        #expect(decoded.spaceID == nil)
        #expect(decoded.selectedTabIDs.isEmpty)
        #expect(decoded.sidebarHidden == false)
        #expect(decoded.frame == nil)
    }
}
