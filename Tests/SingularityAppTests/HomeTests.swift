import AppKit
import Foundation
import MCP
import SwiftUI
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
        state.terminalHandleOverride = { _ in nil } // terminal tabs start no shell
        state.inbox.appIsActive = { false }
        state.inbox.windowIsKey = { false }
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

    // MARK: - The row (Task 4)

    /// The palette's row with `id` for `query` in the home's own mode.
    private func item(_ id: String, _ query: String, _ f: Fixture, mode: PaletteMode) throws -> PaletteItem {
        try #require(PaletteResults.items(for: query, mode: mode, state: f.state).first { $0.id == id })
    }

    @Test func addressTurnsHomeIntoWebTabWithSameID() throws {
        let f = try make()
        defer { finish(f) }
        f.state.openHome()
        let homeID = try #require(f.space.selectedTabID)
        let url = URL(string: "about:blank#home")!
        PaletteResults.perform(PaletteItem(id: "open-url", title: "", subtitle: "", hint: "", icon: .symbol("globe"),
                                           action: .openURL(url)),
                               mode: .home(tabID: homeID), state: f.state)
        let tab = try #require(f.space.tab(homeID))
        #expect(tab.kind == .web(url: url))
        #expect(tab.title != "Home")
        #expect(f.space.selectedTabID == homeID)
        #expect(f.space.tabs.count == 2)
        #expect(!f.space.tabs.contains { $0.isHome })
        #expect(f.state.web.existingController(homeID) != nil)
    }

    @Test func addressRowOnHomeNavigatesInPlace() throws {
        let f = try make()
        defer { finish(f) }
        f.state.openHome()
        let homeID = try #require(f.space.selectedTabID)
        let url = URL(string: "about:blank#row")!
        f.state.navigateSelectedTab(to: url)
        #expect(f.space.tab(homeID)?.kind == .web(url: url))
        #expect(f.space.tabs.count == 2)
    }

    @Test func emptyQueryShowsNoResults() throws {
        let f = try make()
        defer { finish(f) }
        f.state.openHome()
        let homeID = try #require(f.space.selectedTabID)
        #expect(HomeSearch.items(for: "  ", tabID: homeID, state: f.state).isEmpty)
        #expect(!HomeSearch.items(for: "Blank", tabID: homeID, state: f.state).isEmpty)
    }

    @Test func newTerminalFromHomeTakesItsPlace() throws {
        let f = try make()
        defer { finish(f) }
        f.state.openHome()
        let homeID = try #require(f.space.selectedTabID)
        let homeIndex = try #require(f.space.tabs.firstIndex { $0.id == homeID })
        PaletteResults.perform(try item("cmd-new-terminal", "New Terminal", f, mode: .home(tabID: homeID)),
                               mode: .home(tabID: homeID), state: f.state)
        #expect(f.space.tab(homeID) == nil)
        #expect(!f.space.tabs.contains { $0.isHome })
        let selected = try #require(f.space.selectedTab)
        #expect(selected.isTerminal)
        #expect(f.space.tabs.firstIndex { $0.id == selected.id } == homeIndex)
        #expect(f.space.tabs.count == 2)
    }

    @Test func cancelledPickerLeavesHome() throws {
        let f = try make()
        defer { finish(f) }
        f.state.setProjects([Project(name: "api", path: "~/Developer/api")], spaceID: f.spaceID)
        f.state.openHome()
        let homeID = try #require(f.space.selectedTabID)
        PaletteResults.perform(try item("cmd-new-terminal", "New Terminal", f, mode: .home(tabID: homeID)),
                               mode: .home(tabID: homeID), state: f.state)
        guard case .newTerminalIn = f.state.palette else {
            Issue.record("expected the project picker")
            return
        }
        #expect(f.space.selectedTabID == homeID)
        f.state.closePalette()
        #expect(f.state.palette == nil)
        #expect(f.space.tab(homeID)?.isHome == true)
        #expect(f.space.selectedTabID == homeID)
        #expect(f.space.tabs.count == 2)

        // A picker opened later, not from the home, never takes the home's place.
        f.state.selectTab(f.pageID)
        f.state.openTerminalChoosingProject()
        let mode = try #require(f.state.palette)
        PaletteResults.perform(try #require(PaletteResults.items(for: "api", mode: mode, state: f.state).first),
                               mode: mode, state: f.state)
        #expect(f.space.tab(homeID)?.isHome == true)
        #expect(f.space.selectedTab?.isTerminal == true)
    }

    @Test func pickerChoiceTakesTheHomesPlace() throws {
        let f = try make()
        defer { finish(f) }
        f.state.setProjects([Project(name: "api", path: "~/Developer/api")], spaceID: f.spaceID)
        f.state.openHome()
        let homeID = try #require(f.space.selectedTabID)
        let homeIndex = try #require(f.space.tabs.firstIndex { $0.id == homeID })
        PaletteResults.perform(try item("cmd-new-terminal", "New Terminal", f, mode: .home(tabID: homeID)),
                               mode: .home(tabID: homeID), state: f.state)
        let mode = try #require(f.state.palette)
        PaletteResults.perform(try #require(PaletteResults.items(for: "api", mode: mode, state: f.state).first),
                               mode: mode, state: f.state)
        #expect(f.space.tab(homeID) == nil)
        let selected = try #require(f.space.selectedTab)
        #expect(selected.isTerminal)
        #expect(f.space.tabs.firstIndex { $0.id == selected.id } == homeIndex)
    }

    @Test func selectingAnExistingTabLeavesHome() throws {
        let f = try make()
        defer { finish(f) }
        f.state.openHome()
        let homeID = try #require(f.space.selectedTabID)
        PaletteResults.perform(try item("tab-\(f.pageID)", "Blank", f, mode: .home(tabID: homeID)),
                               mode: .home(tabID: homeID), state: f.state)
        #expect(f.space.selectedTabID == f.pageID)
        #expect(f.space.tab(homeID)?.isHome == true)
        #expect(f.space.tabs.count == 2)
    }

    @Test func projectTerminalFromHomeTakesItsPlace() throws {
        let f = try make()
        defer { finish(f) }
        let project = Project(name: "api", path: "~/Developer/api")
        f.state.setProjects([project], spaceID: f.spaceID)
        f.state.openHome()
        let homeID = try #require(f.space.selectedTabID)
        f.state.homeNewTerminal(homeID: homeID, projectID: project.id, launcherID: nil)
        #expect(f.space.tab(homeID) == nil)
        let selected = try #require(f.space.selectedTab)
        #expect(selected.isTerminal)
        #expect(selected.projectID == project.id)
        #expect(f.state.palette == nil)
    }

    // MARK: - The sections (Task 4)

    @Test func homeRowsShowCleanedTerminalTitles() throws {
        let f = try make()
        defer { finish(f) }
        var terminalID: UUID?
        f.state.mutateSpace(f.spaceID) {
            terminalID = $0.addTerminal(directory: "~/Developer", projectID: nil, inFolder: nil, select: false)
            $0.updateTab(terminalID!) { $0.title = "evil\u{1B}[31m\u{202E}  title\u{7}" }
        }
        let id = try #require(terminalID)
        f.state.inbox.terminalSignal(.notification(title: "x", body: "Which\u{1B}[2J option?\nsecond line"),
                                     tabID: id, spaceID: f.spaceID, foregroundProgram: "claude")
        let rows = HomeOverview.terminals(state: f.state, space: f.space)
        let row = try #require(rows.first { $0.id == id })
        #expect(row.title == InboxText.clean(f.space.tab(id)!.displayTitle, limit: HomeOverview.titleLimit))
        #expect(!row.title.unicodeScalars.contains { $0.properties.generalCategory == .control || $0.value == 0x202E })
        #expect(row.state == .waiting)

        let waiting = HomeOverview.waiting(state: f.state, space: f.space)
        let entry = try #require(waiting.first { $0.tabID == id })
        #expect(!entry.line.unicodeScalars.contains { $0.properties.generalCategory == .control })
        #expect(!entry.title.unicodeScalars.contains { $0.properties.generalCategory == .control || $0.value == 0x202E })
        #expect(!entry.isApproval)
        // Another Space's entries are not this home's.
        #expect(HomeOverview.waiting(state: f.state, space: f.state.space(f.otherSpaceID)!).isEmpty)
    }

    @Test func newMarkAfterLeaving() throws {
        let f = try make()
        defer { finish(f) }
        var terminalID: UUID?
        f.state.mutateSpace(f.spaceID) {
            terminalID = $0.addTerminal(directory: "~/Developer", projectID: nil, inFolder: nil, select: false)
        }
        let id = try #require(terminalID)
        f.state.openHome()
        f.state.inbox.terminalSignal(.notification(title: "x", body: "first"), tabID: id, spaceID: f.spaceID,
                                     foregroundProgram: "claude")
        // Never left the home yet: nothing is new.
        #expect(HomeOverview.terminals(state: f.state, space: f.space).first { $0.id == id }?.isNew == false)

        f.state.selectTab(f.pageID) // the home leaves the screen
        let left = try #require(f.state.homeLeftAt[f.spaceID])
        f.state.inbox.now = { left.addingTimeInterval(5) }
        f.state.inbox.terminalSignal(.programExited, tabID: id, spaceID: f.spaceID, foregroundProgram: nil)
        let row = try #require(HomeOverview.terminals(state: f.state, space: f.space).first { $0.id == id })
        #expect(row.state == .idle)
        #expect(row.isNew)
    }

    @Test func boardChangesAreObserved() throws {
        let f = try make()
        defer { finish(f) }
        var terminalID: UUID?
        f.state.mutateSpace(f.spaceID) {
            terminalID = $0.addTerminal(directory: "~/Developer", projectID: nil, inFolder: nil, select: false)
        }
        let id = try #require(terminalID)
        let before = f.state.inbox.boardRevision
        f.state.inbox.terminalSignal(.programExited, tabID: id, spaceID: f.spaceID, foregroundProgram: nil)
        #expect(f.state.inbox.boardRevision == before + 1)
        // The same state again changes nothing on the board.
        f.state.inbox.terminalSignal(.programExited, tabID: id, spaceID: f.spaceID, foregroundProgram: nil)
        #expect(f.state.inbox.boardRevision == before + 1)
    }

    @Test func homeRowLeavesTheHomeOut() throws {
        let f = try make()
        defer { finish(f) }
        f.state.openHome()
        let homeID = try #require(f.space.selectedTabID)
        for query in ["home", "ho", "e"] {
            let items = HomeSearch.items(for: query, tabID: homeID, state: f.state)
            #expect(!items.contains { $0.id == "tab-\(homeID)" }, "\(query)")
        }
        #expect(HomeSearch.items(for: "home", tabID: homeID, state: f.state).first?.id == "search")
    }

    @Test func recentListsNotesArtifactsAndApps() throws {
        MainRunLoopGuard.start
        let dir = FileManager.default.temporaryDirectory.appending(path: "sg-home-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: dir) }
        let notes = dir.appending(path: "notes"), artifacts = dir.appending(path: "artifacts")
        let fm = FileManager.default
        try fm.createDirectory(at: notes.appending(path: "Journal"), withIntermediateDirectories: true)
        try fm.createDirectory(at: artifacts.appending(path: "invoices"), withIntermediateDirectories: true)
        try Data("# a".utf8).write(to: notes.appending(path: "Journal/today.md"))
        try Data("<p>".utf8).write(to: artifacts.appending(path: "dashboard.html"))
        try Data("{}".utf8).write(to: artifacts.appending(path: "invoices/wrangler.jsonc"))
        try Data("<p>".utf8).write(to: artifacts.appending(path: "invoices/index.html"))
        try Data("<p>".utf8).write(to: artifacts.appending(path: "invoices/other.html"))
        let old = Date(timeIntervalSinceNow: -3600)
        try fm.setAttributes([.modificationDate: old], ofItemAtPath: artifacts.appending(path: "dashboard.html").path)

        let files = HomeRecentLoader.load(notesRoot: notes, artifactsRoot: artifacts)
        #expect(files.contains(HomeRecentFile(kind: .note, path: "Journal/today.md", modified: files.first { $0.kind == .note }!.modified)))
        #expect(files.filter { $0.kind == .app }.map(\.path) == ["invoices"])
        #expect(files.filter { $0.kind == .artifact }.map(\.path) == ["dashboard.html"])
        #expect(files.last?.path == "dashboard.html") // the oldest last
        // Missing folders are read as empty, never made.
        let none = dir.appending(path: "nothing")
        #expect(HomeRecentLoader.load(notesRoot: none, artifactsRoot: none).isEmpty)
        #expect(!fm.fileExists(atPath: none.path))
    }

    /// A smoke render of the home in a window far off screen that is never made key (the home here
    /// is not the selected tab, so its row doesn't take the focus). With `SG_SNAPSHOT_DIR` set it
    /// also writes `home.png` there to look at.
    @Test func homeRenders() async throws {
        let f = try make()
        defer { finish(f) }
        f.state.setProjects([Project(name: "api-server", path: "~/Developer/api"), Project(name: "web", path: "~/Developer/web")],
                            spaceID: f.spaceID)
        var ids: [UUID] = []
        f.state.mutateSpace(f.spaceID) { space in
            for title in ["claude · api", "codex · web", "zsh"] {
                let id = space.addTerminal(directory: "~/Developer", projectID: space.projects.first?.id, inFolder: nil, select: false)
                space.updateTab(id) { $0.title = title }
                ids.append(id)
            }
        }
        f.state.inbox.terminalSignal(.notification(title: "x", body: "Which option?"), tabID: ids[0], spaceID: f.spaceID,
                                     foregroundProgram: "claude")
        f.state.inbox.terminalSignal(.programExited, tabID: ids[2], spaceID: f.spaceID, foregroundProgram: nil)
        f.state.openHome()
        let homeID = try #require(f.space.selectedTabID)
        f.state.selectTab(f.pageID)

        let size = NSSize(width: 900, height: 760)
        let window = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: size.width, height: size.height),
                              styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: HomeView(tabID: homeID).environment(f.state)
            .frame(width: size.width, height: size.height))
        window.contentView = host
        window.orderFront(nil) // in front of nothing on screen; never made key or active
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(500))
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        #expect(!window.isKeyWindow)
        if let folder = ProcessInfo.processInfo.environment["SG_SNAPSHOT_DIR"], let png = rep.representation(using: .png, properties: [:]) {
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            try png.write(to: URL(filePath: folder).appending(path: "home.png"))
        }
        let first = rep.colorAt(x: 2, y: 2)
        var drawn = false
        for x in stride(from: 4, to: rep.pixelsWide, by: 9) where !drawn {
            for y in stride(from: 4, to: rep.pixelsHigh, by: 9) where rep.colorAt(x: x, y: y) != first { drawn = true; break }
        }
        #expect(drawn)
    }

    private func text(_ result: CallTool.Result) -> String {
        result.content.compactMap { content -> String? in
            if case .text(let text, _, _) = content { return text }
            return nil
        }.joined(separator: "\n")
    }
}
}
