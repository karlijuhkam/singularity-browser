import Foundation
import MCP
import Testing
@testable import Singularity
import SingularityCore

extension AppTests {
/// The Space's home (⌘T) through the real `AppState`. No test here starts a shell, makes a
/// window key or loads a page from the network (the only web tab is `about:blank`).
@MainActor
@Suite(.serialized) struct HomeTests {
    @MainActor struct Fixture {
        let root: URL
        let state: AppState
        let spaceID: UUID
        let otherSpaceID: UUID
        let pageID: UUID
        var space: Space { state.space(spaceID)! }
    }

    /// Space "Work" with one blank page (not selected), and an empty Space "Other".
    func make() throws -> Fixture {
        MainRunLoopGuard.start
        let root = TestAppState.makeRoot()
        let store = SpaceStore(paths: Paths(root: root))
        var work = Space(name: "Work", slug: "work", colorHex: "#5E81F4", workingDirectory: "~/Developer")
        let page = BrowserTab.web(URL(string: "about:blank")!, title: "Blank")
        work.append(page)
        work.selectedTabID = nil
        try store.save(work)
        let other = Space(name: "Other", slug: "other", colorHex: "#E5534B", workingDirectory: "~/Developer")
        try store.save(other)
        let state = TestAppState.make(root: root)
        state.selectSpace(work.id)
        return Fixture(root: root, state: state, spaceID: work.id, otherSpaceID: other.id, pageID: page.id)
    }

    func finish(_ f: Fixture) {
        TestAppState.shutDown(f.state)
        try? FileManager.default.removeItem(at: f.root)
    }

    @Test func openHomeMakesAHomeTab() throws {
        let f = try make()
        defer { finish(f) }
        f.state.openHome()
        let selected = try #require(f.space.selectedTab)
        #expect(selected.isHome)
        #expect(selected.title == "Home")
        #expect(f.space.tabs.count == 2)
        #expect(f.space.tabs.last?.id == selected.id) // where New Tab puts new tabs: at the end
    }

    @Test func openHomeTwiceMakesOneTab() throws {
        let f = try make()
        defer { finish(f) }
        f.state.openHome()
        f.state.openHome()
        #expect(f.space.tabs.filter(\.isHome).count == 1)
        let homeID = try #require(f.space.selectedTab?.id)

        // Away on another tab, ⌘T comes back to the same home.
        f.state.selectTab(f.pageID)
        #expect(f.space.selectedTabID == f.pageID)
        f.state.openHome()
        #expect(f.space.selectedTabID == homeID)
        #expect(f.space.tabs.filter(\.isHome).count == 1)
    }

    @Test func openHomeClosesTheWelcomeFlow() throws {
        let f = try make()
        defer { finish(f) }
        f.state.showWelcome()
        #expect(f.state.welcomeCoversWindow)
        f.state.openHome()
        #expect(!f.state.welcomeCoversWindow)
        #expect(f.space.selectedTab?.isHome == true)
    }

    @Test func leavingTheHomeNotesWhenInMemory() throws {
        let f = try make()
        defer { finish(f) }
        f.state.openHome()
        #expect(f.state.homeLeftAt[f.spaceID] == nil)
        let before = Date()
        f.state.selectSpace(f.otherSpaceID) // the other Space is empty: its own home shows now
        let left = try #require(f.state.homeLeftAt[f.spaceID])
        #expect(left >= before)
        #expect(f.state.homeLeftAt[f.otherSpaceID] == nil)
        f.state.selectSpace(f.spaceID)
        #expect(f.state.homeLeftAt[f.otherSpaceID] != nil)
    }

    @Test func listTabsLeavesHomeOut() async throws {
        let f = try make()
        defer { finish(f) }
        f.state.setAgentsEnabled(true, spaceID: f.spaceID)
        f.state.openHome()
        let home = try #require(f.space.selectedTab)
        let toolbox = AgentToolbox(state: f.state)

        let list = await toolbox.call("work.list_tabs", arguments: [:], client: "test", caller: .outside)
        #expect(list.isError != true)
        #expect(text(list).contains(f.pageID.uuidString.lowercased()))
        #expect(!text(list).contains(home.id.uuidString.lowercased()))

        for tool in ["read_page", "screenshot", "close"] {
            let result = await toolbox.call("work.\(tool)", arguments: ["tab_id": .string(home.id.uuidString.lowercased())],
                                            client: "test", caller: .outside)
            #expect(result.isError == true, "\(tool)")
            #expect(text(result).contains("not a web page"), "\(tool): \(text(result))")
        }
        #expect(f.space.tab(home.id) != nil)
    }

    @Test func frontNamesHomeKindOnly() throws {
        let f = try make()
        defer { finish(f) }
        f.state.openHome()
        let home = try #require(f.space.selectedTab)
        guard case .tab(let front) = PluginReach.front(pluginID: "x", space: f.space, spaceIsOpen: true,
                                                       welcomeCoversWindow: false, lastOtherPane: nil) else {
            Issue.record("expected the home as the tab in front")
            return
        }
        #expect(front.tab.kind == "home")
        #expect(front.tab.id == home.id.uuidString.lowercased())
        #expect(front.tab.title == nil)
        #expect(front.tab.url == nil)
    }

    private func text(_ result: CallTool.Result) -> String {
        result.content.compactMap { content -> String? in
            if case .text(let text, _, _) = content { return text }
            return nil
        }.joined(separator: "\n")
    }
}
}
