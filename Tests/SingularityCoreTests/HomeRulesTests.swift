import Foundation
import Testing
@testable import SingularityCore

@Suite struct HomeRulesTests {
    /// A Space with web tabs A, B, C (open, in that order) and A selected.
    func makeSpace() -> (Space, [UUID]) {
        var space = Space(name: "Work", slug: "work", colorHex: "#5E81F4")
        for letter in ["A", "B", "C"] {
            space.append(.web(URL(string: "https://\(letter.lowercased()).test")!, title: letter))
        }
        let ids = space.tabs.map(\.id)
        space.selectedTabID = ids[0]
        return (space, ids)
    }

    @Test func homeKindRoundTripsThroughJSON() throws {
        let home = BrowserTab.home()
        #expect(home.title == "Home")
        #expect(home.isHome)
        let data = try JSONEncoder().encode(home)
        let decoded = try JSONDecoder().decode(BrowserTab.self, from: data)
        #expect(decoded == home)
        #expect(decoded.kind == .home)
        #expect(decoded.isHome)
    }

    @Test func homeIsHiddenFromAgents() {
        var home = BrowserTab.home()
        #expect(home.isHiddenFromAgents)
        #expect(home.url == nil)
        #expect(home.workingDirectory == nil)
        #expect(home.artifactPath == nil)
        #expect(!home.isTerminal && !home.isArtifact && !home.isPlugin && !home.isNote)
        home.title = ""
        #expect(home.displayTitle == "Home")
        #expect(!BrowserTab.web(URL(string: "https://a.test")!).isHome)
    }

    @Test func reusableHomeFindsTheExistingOne() {
        var (space, _) = makeSpace()
        #expect(HomeRules.reusableHome(in: space) == nil)
        let home = BrowserTab.home()
        space.append(home)
        space.append(.home())
        #expect(HomeRules.reusableHome(in: space) == home.id)
    }

    @Test func replaceKeepsPositionFolderAndPin() {
        var (space, t) = makeSpace()
        let folderID = UUID()
        var home = BrowserTab.home()
        home.isPinned = true
        home.folderID = folderID
        space.insert(home, after: t[0])   // A, Home, B, C
        let terminal = BrowserTab.terminal(workingDirectory: "~")
        space.append(terminal)             // A, Home, B, C, T
        space.selectedTabID = terminal.id
        space.replaceHome(home.id, with: terminal.id)
        #expect(space.tabs.map(\.id) == [t[0], terminal.id, t[1], t[2]])
        #expect(space.tab(home.id) == nil)
        #expect(space.tab(terminal.id)?.isPinned == true)
        #expect(space.tab(terminal.id)?.folderID == folderID)
        #expect(space.selectedTabID == terminal.id)
    }

    @Test func replaceWithMissingIdsChangesNothing() {
        var (space, t) = makeSpace()
        let home = BrowserTab.home()
        space.append(home)
        let before = space
        space.replaceHome(home.id, with: UUID())
        #expect(space == before)
        space.replaceHome(UUID(), with: t[1])
        #expect(space == before)
    }

    @Test func replaceKeepsSplitPane() {
        var (space, t) = makeSpace()
        let home = BrowserTab.home()
        space.append(home)
        space.split(home.id, beside: t[0], edge: .right)   // H[A,Home]
        let note = BrowserTab.note(path: "Today.md")
        space.append(note)
        space.selectedTabID = note.id
        space.replaceHome(home.id, with: note.id)
        #expect(space.splits.count == 1)
        #expect(space.splits[0].root.tabIDs == [t[0], note.id])
        #expect(space.tab(home.id) == nil)
        #expect(space.selectedTabID == note.id)
    }

    @Test func tabToReplaceHomeIgnoresExistingTabs() {
        var (space, t) = makeSpace()
        let home = BrowserTab.home()
        space.append(home)
        space.selectedTabID = home.id
        let before = Set(space.tabs.map(\.id))
        // Nothing new: the home itself is selected.
        #expect(HomeRules.tabToReplaceHome(before: before, after: space) == nil)
        // Going to an existing tab: not a replacement.
        space.selectedTabID = t[1]
        #expect(HomeRules.tabToReplaceHome(before: before, after: space) == nil)
        // A new tab, selected: that one.
        let terminal = BrowserTab.terminal(workingDirectory: "~")
        space.append(terminal)
        space.selectedTabID = terminal.id
        #expect(HomeRules.tabToReplaceHome(before: before, after: space) == terminal.id)
        // A new tab that isn't selected: nothing.
        space.selectedTabID = t[0]
        #expect(HomeRules.tabToReplaceHome(before: before, after: space) == nil)
        // A new home is never a replacement.
        let otherHome = BrowserTab.home()
        space.append(otherHome)
        space.selectedTabID = otherHome.id
        #expect(HomeRules.tabToReplaceHome(before: before, after: space) == nil)
    }

    @Test func terminalOrderIsWaitingWorkingDoneIdleUnknown() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let ids = (0..<7).map { _ in UUID() }
        let rows: [(id: UUID, state: TerminalBoard.State, since: Date)] = [
            (ids[0], .unknown, now),
            (ids[1], .idle, now),
            (ids[2], .done, now.addingTimeInterval(-60)),
            (ids[3], .working, now),
            (ids[4], .waiting, now.addingTimeInterval(-120)),
            (ids[5], .done, now),
            (ids[6], .waiting, now),
        ]
        #expect(HomeRules.terminalOrder(rows) == [ids[6], ids[4], ids[3], ids[5], ids[2], ids[1], ids[0]])
    }

    @Test func isNewOnlyAfterLastLeft() {
        let left = Date(timeIntervalSince1970: 1_000)
        #expect(!HomeRules.isNew(since: left.addingTimeInterval(10), lastLeft: nil))
        #expect(HomeRules.isNew(since: left.addingTimeInterval(10), lastLeft: left))
        #expect(!HomeRules.isNew(since: left, lastLeft: left))
        #expect(!HomeRules.isNew(since: left.addingTimeInterval(-10), lastLeft: left))
    }

    @Test func recentIsNewestFirstAndCutAtEight() {
        let base = Date(timeIntervalSince1970: 1_000)
        let files = (0..<10).map { i in
            HomeRecentFile(kind: i.isMultiple(of: 2) ? .note : .artifact, path: "f\(i)",
                           modified: base.addingTimeInterval(Double((i * 7) % 10)))
        }
        let recent = HomeRules.recent(files)
        #expect(recent.count == 8)
        #expect(recent.map(\.modified) == recent.map(\.modified).sorted(by: >))
        #expect(recent.first?.modified == base.addingTimeInterval(9))
        #expect(HomeRules.recent(files, limit: 3).count == 3)
        #expect(HomeRules.recent([]).isEmpty)
    }
}
