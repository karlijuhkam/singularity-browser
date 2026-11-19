import Foundation
import Testing
@testable import SingularityCore

@Suite struct SplitTests {
    /// A Space with tabs A…G (all open, in that order) and A selected.
    func makeSpace() -> (Space, [UUID]) {
        var space = Space(name: "Work", slug: "work", colorHex: "#5E81F4")
        for letter in ["A", "B", "C", "D", "E", "F", "G"] {
            space.append(.web(URL(string: "https://\(letter.lowercased()).test")!, title: letter))
        }
        let ids = space.tabs.map(\.id)
        space.selectedTabID = ids[0]
        return (space, ids)
    }

    /// The layout as nested text, e.g. "H[A,V[B,C]]", for readable expectations.
    func describe(_ node: SplitNode, _ space: Space) -> String {
        switch node {
        case .pane(let id): return space.tab(id)?.title ?? "?"
        case .split(let axis, let children, _):
            return (axis == .horizontal ? "H" : "V") + "[" + children.map { describe($0, space) }.joined(separator: ",") + "]"
        }
    }

    @Test func createAndNest() throws {
        var (space, t) = makeSpace()
        let ok1 = space.split(t[1], beside: t[0], edge: .right)
        #expect(ok1)
        #expect(describe(space.splits[0].root, space) == "H[A,B]")
        // B below → nested vertical container replaces B's pane.
        space.split(t[2], beside: t[1], edge: .bottom)
        #expect(describe(space.splits[0].root, space) == "H[A,V[B,C]]")
        // Same axis as the parent → becomes a sibling, sharing the target's space.
        space.split(t[3], beside: t[0], edge: .left)
        #expect(describe(space.splits[0].root, space) == "H[D,A,V[B,C]]")
        guard case .split(_, _, let fractions) = space.splits[0].root else { Issue.record("not a split"); return }
        #expect(fractions == [0.25, 0.25, 0.5])
        #expect(space.splits.count == 1)
        #expect(Set(space.visibleTabIDs) == Set([t[0], t[1], t[2], t[3]]))
    }

    @Test func removeCollapsesAndDissolves() {
        var (space, t) = makeSpace()
        space.split(t[1], beside: t[0], edge: .right)
        space.split(t[2], beside: t[1], edge: .bottom)   // H[A,V[B,C]]
        space.removeFromSplit(t[2])
        #expect(describe(space.splits[0].root, space) == "H[A,B]")
        space.removeFromSplit(t[1])
        #expect(space.splits.isEmpty) // one pane left: the split dissolves
        #expect(space.visibleTabIDs == [t[0]])
    }

    @Test func collapsingMergesSameAxisContainers() {
        var (space, t) = makeSpace()
        space.split(t[1], beside: t[0], edge: .right)    // H[A,B]
        space.split(t[2], beside: t[1], edge: .bottom)   // H[A,V[B,C]]
        space.split(t[3], beside: t[2], edge: .right)    // H[A,V[B,H[C,D]]]
        #expect(describe(space.splits[0].root, space) == "H[A,V[B,H[C,D]]]")
        space.removeFromSplit(t[1])                      // V has one child left → H[C,D] merges into the root
        #expect(describe(space.splits[0].root, space) == "H[A,C,D]")
        let total = space.splits[0].root.layoutRects().values.map { $0.width * $0.height }.reduce(0, +)
        #expect(abs(total - 1) < 1e-9)
    }

    @Test func movingATabBetweenSplits() {
        var (space, t) = makeSpace()
        space.split(t[1], beside: t[0], edge: .right)    // group 1: A,B
        space.split(t[3], beside: t[2], edge: .right)    // group 2: C,D
        #expect(space.splits.count == 2)
        space.split(t[1], beside: t[2], edge: .bottom)   // B leaves group 1 (which dissolves)
        #expect(space.splits.count == 1)
        #expect(describe(space.splits[0].root, space) == "H[V[C,B],D]")
        #expect(space.splitGroup(containing: t[0]) == nil)
    }

    @Test func replaceAndCap() {
        var (space, t) = makeSpace()
        space.split(t[1], beside: t[0], edge: .right)
        space.replaceInSplit(t[1], with: t[2])
        #expect(describe(space.splits[0].root, space) == "H[A,C]")
        for i in 3...6 where i < 6 { space.split(t[i], beside: t[0], edge: .bottom) }
        #expect(space.splits[0].root.tabIDs.count == 5)
        let ok2 = space.split(t[1], beside: t[0], edge: .right)
        #expect(ok2)   // sixth pane is allowed
        let ok3 = space.split(t[6], beside: t[0], edge: .right)
        #expect(!ok3)  // seventh is refused
        let ok4 = space.split(t[0], beside: t[0], edge: .right)
        #expect(!ok4)  // a tab can't split with itself
    }

    @Test func reorderingTwoPanes() {
        var (space, t) = makeSpace()
        space.split(t[1], beside: t[0], edge: .right)        // H[A,B]
        space.replaceInSplit(t[1], with: t[0])                // A dropped on B's middle → swap
        #expect(describe(space.splits[0].root, space) == "H[B,A]")
        space.split(t[1], beside: t[0], edge: .right)        // B dropped on A's right edge → H[A,B]
        #expect(describe(space.splits[0].root, space) == "H[A,B]")
        #expect(space.splits.count == 1)
    }

    @Test func swappingKeepsSizesAndOtherPanes() {
        var (space, t) = makeSpace()
        space.split(t[1], beside: t[0], edge: .right)
        space.split(t[2], beside: t[1], edge: .bottom)       // H[A,V[B,C]]
        space.setSplitFractions(groupID: space.splits[0].id, path: [], fractions: [0.3, 0.7])
        let swapped = space.swapInSplit(t[0], t[2])
        #expect(swapped)
        #expect(describe(space.splits[0].root, space) == "H[C,V[B,A]]")
        guard case .split(_, _, let fractions) = space.splits[0].root else { Issue.record("not a split"); return }
        #expect(abs(fractions[0] - 0.3) < 1e-9)              // the layout's sizes stay put
    }

    @Test func neighbours() {
        var (space, t) = makeSpace()
        space.split(t[1], beside: t[0], edge: .right)
        space.split(t[2], beside: t[1], edge: .bottom)   // A | B over C
        let root = space.splits[0].root
        #expect(root.neighbour(of: t[0], .right) == t[1])     // A touches B and C equally: the top one wins
        #expect(root.neighbour(of: t[1], .down) == t[2])
        #expect(root.neighbour(of: t[2], .up) == t[1])
        #expect(root.neighbour(of: t[2], .left) == t[0])
        #expect(root.neighbour(of: t[0], .left) == nil)
    }

    @Test func closingATabInASplit() {
        var (space, t) = makeSpace()
        space.split(t[1], beside: t[0], edge: .right)
        space.split(t[2], beside: t[0], edge: .right)    // H[A,C,B]
        space.selectedTabID = t[2]
        space.closeTab(t[2])
        #expect(describe(space.splits[0].root, space) == "H[A,B]")
        #expect(space.selectedTabID == t[0])             // focus stays inside the split
    }

    @Test func persistence() throws {
        var (space, t) = makeSpace()
        space.split(t[1], beside: t[0], edge: .bottom)
        space.setSplitFractions(groupID: space.splits[0].id, path: [], fractions: [0.7, 0.3])
        let decoded = try JSONDecoder().decode(Space.self, from: JSONEncoder().encode(space))
        #expect(decoded.splits == space.splits)
        guard case .split(.vertical, _, let fractions) = decoded.splits[0].root else { Issue.record("bad root"); return }
        #expect(abs(fractions[0] - 0.7) < 1e-9)
    }
}

@Suite struct SidebarItemTests {
    @Test func splitIsOneRowAtItsFirstTab() {
        var (space, t) = SplitTests().makeSpace()          // A B C D E F G, all open
        space.split(t[3], beside: t[1], edge: .right)      // split of B and D
        let items = space.sidebarItems(in: .open)
        #expect(items.map(\.tabIDs) == [[t[0]], [t[1], t[3]], [t[2]], [t[4]], [t[5]], [t[6]]])
    }

    @Test func splitAcrossSectionsShowsInFirstSectionOnly() {
        var (space, t) = SplitTests().makeSpace()
        space.moveTab(t[2], to: .pinned)                   // C pinned
        space.split(t[0], beside: t[2], edge: .right)      // split of C (pinned) and A (open)
        #expect(space.sidebarItems(in: .pinned).map(\.tabIDs) == [[t[2], t[0]]])
        #expect(!space.sidebarItems(in: .open).flatMap(\.tabIDs).contains(t[0]))
    }

    @Test func movingASplitRowMovesItsTabsTogether() {
        var (space, t) = SplitTests().makeSpace()
        space.split(t[3], beside: t[1], edge: .right)      // rows: A, [B,D], C, E, F, G
        space.moveSidebarItems(in: .open, fromOffsets: [1], toOffset: 6)   // split row to the end
        #expect(space.sidebarItems(in: .open).map(\.tabIDs) == [[t[0]], [t[2]], [t[4]], [t[5]], [t[6]], [t[1], t[3]]])
        space.moveSidebarItems(in: .open, fromOffsets: [3], toOffset: 0)   // F to the top
        #expect(space.sidebarItems(in: .open).first?.tabIDs == [t[5]])
        #expect(space.tabs.count == 7)
    }

    /// A Space with tabs A…G (open) and folder F holding X and Y.
    func spaceWithFolder() -> (Space, [UUID], Folder, x: UUID, y: UUID) {
        var (space, t) = SplitTests().makeSpace()
        let folder = Folder(name: "F")
        space.folders.append(folder)
        let x = BrowserTab.web(URL(string: "https://x.test")!, title: "X")
        let y = BrowserTab.web(URL(string: "https://y.test")!, title: "Y")
        for tab in [x, y] {
            space.append(tab)
            space.moveTab(tab.id, to: .folder(folder.id))
        }
        return (space, t, folder, x.id, y.id)
    }

    @Test func aSplitMovesToAnotherSectionWithAllItsTabs() throws {
        for (row, expected) in [(0, 0), (1, 1), (Int.max, 2)] {
            var (space, t, folder, x, y) = spaceWithFolder()
            space.split(t[3], beside: t[1], edge: .right)  // [B,D] in Tabs
            let group = try #require(space.splitGroup(containing: t[1]))
            space.moveSplit(group.id, to: .folder(folder.id), atRow: row)
            #expect(space.tab(t[1])?.section == .folder(folder.id))
            #expect(space.tab(t[3])?.section == .folder(folder.id))
            #expect(space.splits == [group])
            #expect(!space.sidebarItems(in: .open).flatMap(\.tabIDs).contains(t[1]))
            var rows: [[UUID]] = [[x], [y]]
            rows.insert([t[1], t[3]], at: expected)
            #expect(space.sidebarItems(in: .folder(folder.id)).map(\.tabIDs) == rows)
            #expect(space.tabs.count == 9)
        }
    }

    @Test func aSplitMovesIntoAnEmptyPinnedSection() throws {
        var (space, t) = SplitTests().makeSpace()
        space.split(t[3], beside: t[1], edge: .right)
        let group = try #require(space.splitGroup(containing: t[1]))
        space.moveSplit(group.id, to: .pinned, atRow: .max)
        for id in [t[1], t[3]] {
            #expect(space.tab(id)?.isPinned == true)
            #expect(space.tab(id)?.folderID == nil)
        }
        #expect(space.sidebarItems(in: .pinned) == [.split(groupID: group.id, tabIDs: [t[1], t[3]])])
    }

    @Test func aSplitWithTabsInSeveralSectionsIsGatheredOnMove() throws {
        var (space, t, folder, x, _) = spaceWithFolder()
        space.moveTab(t[2], to: .pinned)                    // C pinned
        space.split(x, beside: t[2], edge: .right)          // C (pinned) and X (folder)
        space.split(t[5], beside: x, edge: .bottom)         // and F (open), as a terminal in a split
        let group = try #require(space.splitGroup(containing: t[2]))
        #expect(space.splitGroup(containing: t[5])?.id == group.id)
        space.moveSplit(group.id, to: .open, atRow: 1)      // between A and B
        let open = space.tabs(in: .open).map(\.id)
        // Side by side, in their old sidebar order (pinned C, folder X, open F), before B.
        #expect(open == [t[0], t[2], x, t[5], t[1], t[3], t[4], t[6]])
        #expect(space.sidebarItems(in: .open).filter { $0.tabIDs.count > 1 }.count == 1)
        #expect(space.sidebarItems(in: .pinned).isEmpty)
        #expect(space.tabs(in: .folder(folder.id)).count == 1)
    }

    @Test func movingASplitWithinItsSectionAndOntoItsOwnPlace() throws {
        var (space, t) = SplitTests().makeSpace()
        space.split(t[3], beside: t[1], edge: .right)       // rows: A, [B,D], C, E, F, G
        let group = try #require(space.splitGroup(containing: t[1]))
        // Onto its own place (its row, or the gap after it): the rows stay as they were; its
        // tabs B and D, apart in the array (C is between them), become neighbours.
        let before = space.sidebarItems(in: .open)
        space.moveSplit(group.id, to: .open, atRow: 1)
        #expect(space.sidebarItems(in: .open) == before)
        #expect(space.tabs.map(\.id) == [t[0], t[1], t[3], t[2], t[4], t[5], t[6]])
        space.moveSplit(group.id, to: .open, atRow: 2)
        #expect(space.sidebarItems(in: .open) == before)
        #expect(space.tabs.map(\.id) == [t[0], t[1], t[3], t[2], t[4], t[5], t[6]])
        space.moveSplit(group.id, to: .open, atRow: 4)      // before F
        #expect(space.sidebarItems(in: .open).map(\.tabIDs) == [[t[0]], [t[2]], [t[4]], [t[1], t[3]], [t[5]], [t[6]]])
        space.moveSplit(group.id, to: .open, atRow: 0)
        #expect(space.sidebarItems(in: .open).first?.tabIDs == [t[1], t[3]])
    }

    @Test func movingASplitToAnUnknownFolderOrAnUnknownSplitChangesNothing() throws {
        var (space, t) = SplitTests().makeSpace()
        space.split(t[3], beside: t[1], edge: .right)
        let group = try #require(space.splitGroup(containing: t[1]))
        let before = space
        space.moveSplit(group.id, to: .folder(UUID()), atRow: 0)
        space.moveSplit(UUID(), to: .pinned, atRow: 0)
        #expect(space == before)
    }

    @Test func aTabOfASplitStandsForItsSplit() throws {
        var (a, t, folder, _, _) = spaceWithFolder()
        a.split(t[3], beside: t[1], edge: .right)
        var b = a
        let group = try #require(a.splitGroup(containing: t[1]))
        a.moveTab(t[3], to: .folder(folder.id), atRow: 1)
        b.moveSplit(group.id, to: .folder(folder.id), atRow: 1)
        #expect(a.tabs.map(\.id) == b.tabs.map(\.id))
        #expect(a.tabs.map(\.section) == b.tabs.map(\.section))
    }
}

@Suite struct TabDragPayloadTests {
    @Test func roundTrips() {
        let id = UUID()
        #expect(TabDragPayload(string: "split:" + id.uuidString) == .split(groupID: id))
        #expect(TabDragPayload(string: id.uuidString) == .tab(id))
        #expect(TabDragPayload(string: TabDragPayload.split(groupID: id).string) == .split(groupID: id))
        #expect(TabDragPayload(string: TabDragPayload.tab(id).string) == .tab(id))
        #expect(TabDragPayload(string: "") == nil)
        #expect(TabDragPayload(string: "split:") == nil)
        #expect(TabDragPayload(string: "split:nonsense") == nil)
        #expect(TabDragPayload(string: "hello") == nil)
        // Why the panes ignore a split's row: it is not a tab id.
        #expect(UUID(uuidString: "split:" + id.uuidString) == nil)
    }
}

/// New tabs straight into a split (right-click → Split Right / Split Down, the split palette).
@Suite struct AddInSplitTests {
    func makeSpace() -> (Space, [UUID]) { SplitTests().makeSpace() }
    func describe(_ node: SplitNode, _ space: Space) -> String { SplitTests().describe(node, space) }

    func newTab(_ title: String) -> BrowserTab {
        .web(URL(string: "https://\(title.lowercased()).test")!, title: title)
    }

    @Test func addInSplitPutsTheNewTabRightAfterItsPartner() {
        var (space, t) = makeSpace()
        let new = newTab("N")
        let ok = space.addInSplit(new, beside: t[0], edge: .right)
        #expect(ok)
        #expect(space.tabs.map { $0.title } == ["A", "N", "B", "C", "D", "E", "F", "G"])
        #expect(describe(space.splits[0].root, space) == "H[A,N]")
        #expect(space.selectedTabID == new.id)
        #expect(space.sidebarItems(in: .open).first == .split(groupID: space.splits[0].id, tabIDs: [t[0], new.id]))
    }

    @Test func addInSplitBelowStacks() {
        var (space, t) = makeSpace()
        space.addInSplit(newTab("N"), beside: t[0], edge: .bottom)
        #expect(describe(space.splits[0].root, space) == "V[A,N]")
    }

    @Test func addInSplitGoesAfterTheSplitsLastTab() {
        var (space, t) = makeSpace()
        space.split(t[3], beside: t[0], edge: .right)  // [A,D]
        space.addInSplit(newTab("N"), beside: t[0], edge: .bottom)
        #expect(space.tabs.map { $0.title } == ["A", "B", "C", "D", "N", "E", "F", "G"])
        #expect(describe(space.splits[0].root, space) == "H[V[A,N],D]")
    }

    @Test func addInSplitInAFolderJoinsTheFolder() {
        var (space, _, folder, x, y) = SidebarItemTests().spaceWithFolder()
        let new = newTab("N")
        space.addInSplit(new, beside: x, edge: .right)
        #expect(space.tab(new.id)?.folderID == folder.id)
        #expect(space.tabs(in: .folder(folder.id)).map { $0.title } == ["X", "N", "Y"])
        #expect(space.sidebarItems(in: .folder(folder.id)).count == 2) // the split's row, then Y
        #expect(!space.sidebarItems(in: .open).contains { $0.tabIDs.contains(new.id) })
    }

    @Test func addInSplitBesideALaterPaneUsesTheRowsFolder() {
        var (space, t, folder, x, _) = SidebarItemTests().spaceWithFolder()
        space.split(t[1], beside: x, edge: .right)  // the row lives in F; B is in Tabs
        let new = newTab("N")
        space.addInSplit(new, beside: t[1], edge: .bottom)
        #expect(space.tab(new.id)?.folderID == folder.id)
        #expect(space.tabs(in: .folder(folder.id)).map { $0.title } == ["X", "N", "Y"])
        #expect(space.sidebarItems(in: .folder(folder.id)).first?.tabIDs.contains(new.id) == true)
    }

    @Test func addInSplitBesideAPinnedTabNeverPins() {
        var (space, t) = makeSpace()
        space.moveTab(t[0], to: .pinned)
        var new = newTab("N")
        new.isPinned = true
        space.addInSplit(new, beside: t[0], edge: .right)
        #expect(space.tab(new.id)?.isPinned == false)
        #expect(space.sidebarItems(in: .pinned).first?.tabIDs == [t[0], new.id])
        #expect(!space.sidebarItems(in: .open).contains { $0.tabIDs.contains(new.id) })
    }

    @Test func addInSplitRefusesAFullSplit() {
        var (space, t) = makeSpace()
        for index in 1..<Space.maxPanesPerSplit { space.split(t[index], beside: t[0], edge: .right) }
        #expect(!space.hasRoomInSplit(beside: t[0]))
        #expect(space.hasRoomInSplit(beside: t[6])) // a tab on its own always has room
        let before = space
        let ok = space.addInSplit(newTab("N"), beside: t[1], edge: .bottom)
        #expect(!ok)
        #expect(space == before)
    }

    @Test func addInSplitRefusesAnUnknownTargetOrATabTwice() {
        var (space, t) = makeSpace()
        let before = space
        #expect(!space.hasRoomInSplit(beside: UUID()))
        let ok = space.addInSplit(newTab("N"), beside: UUID(), edge: .right)
        #expect(!ok)
        #expect(space == before)
        let twice = space.addInSplit(space.tab(t[1])!, beside: t[0], edge: .right)
        #expect(!twice)
        #expect(space == before)
    }
}
