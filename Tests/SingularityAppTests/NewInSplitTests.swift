import Foundation
import Testing
@testable import Singularity
import SingularityCore

extension AppTests {
    /// Right-click → Split Right / Split Down → New Tab, New Terminal (or a launcher), New Note,
    /// through the real `AppState`. Terminal tabs are fakes (`terminalHandleOverride`): no shell
    /// starts. Where the new tab goes in the sidebar is covered by Core's `AddInSplitTests`.
    @MainActor @Suite(.serialized) struct NewInSplitTests {
        @MainActor struct Fixture {
            let root: URL
            let state: AppState
            let page: BrowserTab
            var space: Space { state.selectedSpace! }
        }

        private func make(extraTabs: [BrowserTab] = []) throws -> Fixture {
            MainRunLoopGuard.start
            let root = TestAppState.makeRoot()
            let store = SpaceStore(paths: Paths(root: root))
            let page = BrowserTab.web(URL(string: "about:blank")!, title: "page")
            let space = Space(name: "one", slug: "one", colorHex: "#5E81F4", tabs: [page] + extraTabs, selectedTabID: page.id)
            try store.save(space)
            try store.save(AppStateFile(spaceOrder: [space.id], selectedSpaceID: space.id))
            let state = TestAppState.make(root: root)
            state.terminalHandleOverride = { _ in nil }
            return Fixture(root: root, state: state, page: page)
        }

        private func finish(_ f: Fixture) {
            f.state.terminals.tearDownAll()
            TestAppState.shutDown(f.state)
            try? FileManager.default.removeItem(at: f.root)
        }

        @Test func aNewTabIsANewHomeInTheSplit() throws {
            let f = try make()
            defer { finish(f) }
            f.state.newInSplit(.tab, edge: .right, beside: f.page.id)
            let new = try #require(f.state.selectedTab)
            #expect(new.isHome)
            #expect(f.space.tabs.map(\.id) == [f.page.id, new.id])
            #expect(f.space.splitGroup(containing: f.page.id)?.root.tabIDs == [f.page.id, new.id])
        }

        @Test func aLauncherTerminalKeepsItsCommandForTheFirstShell() throws {
            let f = try make()
            defer { finish(f) }
            f.state.newInSplit(.terminal(Launcher(name: "Claude Code", command: "claude")), edge: .bottom, beside: f.page.id)
            let new = try #require(f.state.selectedTab)
            #expect(new.isTerminal)
            #expect(f.space.splitGroup(containing: new.id)?.root.tabIDs == [f.page.id, new.id])
            #expect(f.state.takePendingCommand(new.id) == "claude")
        }

        @Test func aNewNoteMakesItsFileAndGoesInTheSplit() throws {
            let f = try make()
            defer { finish(f) }
            f.state.newInSplit(.note, edge: .right, beside: f.page.id)
            let new = try #require(f.state.selectedTab)
            #expect(new.notePath == "Untitled.md")
            #expect(f.space.splitGroup(containing: new.id) != nil)
            let file = f.state.paths.notesDirectory(f.space.slug).appending(path: "Untitled.md")
            #expect(FileManager.default.fileExists(atPath: file.path))
        }

        @Test func aFullSplitGetsNoStrayTabAndNoNoteFile() throws {
            // Five more homes (they load nothing) and the page: one full split.
            let homes = (0..<(Space.maxPanesPerSplit - 1)).map { _ in BrowserTab.home() }
            let f = try make(extraTabs: homes)
            defer { finish(f) }
            for home in homes { f.state.splitTab(home.id, beside: f.page.id, edge: .right) }
            #expect(f.space.splitGroup(containing: f.page.id)?.root.tabIDs.count == Space.maxPanesPerSplit)
            let before = f.space

            f.state.openInSplit(URL(string: "about:blank")!, edge: .right, beside: f.page.id)
            f.state.newInSplit(.tab, edge: .right, beside: f.page.id)
            f.state.newInSplit(.terminal(nil), edge: .bottom, beside: f.page.id)
            f.state.newInSplit(.note, edge: .right, beside: f.page.id)

            #expect(f.space.tabs == before.tabs)
            #expect(f.space.splits == before.splits)
            let notes = f.state.paths.notesDirectory(f.space.slug)
            #expect(!FileManager.default.fileExists(atPath: notes.appending(path: "Untitled.md").path))
        }
    }
}
