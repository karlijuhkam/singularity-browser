import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Singularity
import SingularityCore

extension AppTests {
    /// The herdr-core terminals under a terminal tab (a Bot's workers): rows from herdr-core's
    /// lines, one shown in the tab's pane, and what that means for ⌘W, closing and the inbox.
    ///
    /// No test runs `hc` or a shell: the lines are fed by hand (`HerdrWatcher.feed`), the tab's
    /// own terminal is switched off through `terminalHandleOverride`, and a child's view is made
    /// without `hc` (herdr-core is off in a test's settings), so it attaches to nothing.
    @MainActor @Suite struct HerdrChildTests {
        @MainActor struct Fixture {
            let root: URL
            let state: AppState
            let space: Space
            let web: BrowserTab
            let bot: BrowserTab
            let plain: BrowserTab
            var botName: String { HerdrCore.terminalName(tabID: bot.id) }
        }

        private func makeFixture() throws -> Fixture {
            MainRunLoopGuard.start
            let root = TestAppState.makeRoot()
            let store = SpaceStore(paths: Paths(root: root))
            let web = BrowserTab.web(URL(string: "about:blank")!, title: "page")
            var bot = BrowserTab.terminal(workingDirectory: "~")
            bot.title = "Bender"
            var plain = BrowserTab.terminal(workingDirectory: "~")
            plain.title = "zsh"
            let space = Space(name: "one", slug: "one", colorHex: "#5E81F4", tabs: [web, bot, plain], selectedTabID: web.id)
            try store.save(space)
            try store.save(AppStateFile(spaceOrder: [space.id], selectedSpaceID: space.id))
            let state = TestAppState.make(root: root)
            // Terminal tabs are fakes here: selecting one starts no shell.
            state.terminalHandleOverride = { _ in nil }
            state.inbox.appIsActive = { true }
            state.inbox.windowIsKey = { true }
            return Fixture(root: root, state: state, space: space, web: web, bot: bot, plain: plain)
        }

        private func tearDown(_ f: Fixture) {
            f.state.terminals.tearDownAll()
            TestAppState.shutDown(f.state)
            try? FileManager.default.removeItem(at: f.root)
        }

        private func json(_ object: Any) -> String {
            String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        }

        private func terminal(_ address: String, name: String, parent: String? = nil, status: String? = nil,
                              labels: [String: String] = [:], created: Int = 0) -> [String: Any] {
            ["address": address, "name": name, "parent": parent ?? NSNull(), "state": "live", "labels": labels,
             "status": status.map { ["app": "claude", "state": $0] } ?? NSNull(), "created_ms": created]
        }

        /// The Bot's tab with a mailbox, two workers under the mailbox and a topic.
        private func feedBot(_ f: Fixture) {
            f.state.herdr.feed(line: json(["seq": 1, "terminals": [
                terminal("t1", name: f.botName),
                terminal("t2", name: "postkast-gwb", parent: "t1", labels: ["role": "postkast"], created: 1),
                terminal("t3", name: "plat135", parent: "t2", status: "working", created: 2),
                terminal("t4", name: "plat77-review", parent: "t2", status: "blocked", created: 3),
                terminal("t5", name: "teema-nortal", parent: "t1", status: "idle", labels: ["role": "topic"], created: 4),
            ]]))
        }

        private func event(_ type: String, _ address: String, _ data: [String: Any] = [:]) -> String {
            json(["jsonrpc": "2.0", "method": "event", "params": ["type": type, "terminal": address, "data": data]])
        }

        @Test func rowsComeFromHerdrCoresLines() throws {
            let f = try makeFixture()
            defer { tearDown(f) }
            #expect(f.state.herdr.children(of: f.bot.id) == .none)
            feedBot(f)
            let children = f.state.herdr.children(of: f.bot.id)
            #expect(children.rows.map(\.name) == ["plat135", "plat77-review", "teema-nortal"])
            #expect(children.rows.map(\.mark) == [.working, .needsYou, .idle])
            #expect(children.needsYou)
            #expect(f.state.herdr.children(of: f.plain.id) == .none)

            f.state.herdr.feed(line: event("finished", "t3"))
            #expect(f.state.herdr.children(of: f.bot.id).rows.map(\.name) == ["plat77-review", "teema-nortal"])
            // Rubbish changes nothing.
            f.state.herdr.feed(line: "not json")
            #expect(f.state.herdr.children(of: f.bot.id).rows.count == 2)
        }

        @Test func aClickShowsTheChildInTheTabsPane() throws {
            let f = try makeFixture()
            defer { tearDown(f) }
            feedBot(f)
            f.state.showChild("t3", under: f.bot.id)
            #expect(f.state.shownChild[f.bot.id] == "t3")
            #expect(f.state.selectedTab?.id == f.bot.id)
            let child = try #require(f.state.terminals.existingChildSession("t3"))
            // Nothing was started: no hc in a test, and the tab's own terminal is a fake.
            #expect(child.view.process?.running != true)
            #expect(f.state.terminals.existingSession(f.bot.id) == nil)

            // The same view the second time, another one for another child.
            f.state.showChild("t4", under: f.bot.id)
            f.state.showChild("t3", under: f.bot.id)
            #expect(f.state.terminals.existingChildSession("t3") === child)

            f.state.showOwnTerminal(f.bot.id)
            #expect(f.state.shownChild[f.bot.id] == nil)
            #expect(f.state.selectedTab?.id == f.bot.id)
        }

        /// In a split the tab has no row of its own, only a chip: the chip's click (which calls
        /// `showOwnTerminal`) must bring its own terminal back, while a click in the pane keeps the child.
        @Test func aChipInASplitBringsTheOwnTerminalBack() throws {
            let f = try makeFixture()
            defer { tearDown(f) }
            feedBot(f)
            f.state.splitTab(f.bot.id, beside: f.web.id, edge: .right)
            #expect(f.state.selectedSpace?.splitGroup(containing: f.bot.id) != nil)
            f.state.showChild("t3", under: f.bot.id)
            #expect(f.state.shownChild[f.bot.id] == "t3")

            // Focusing the other pane, or a click in the Bot's pane, keeps the child.
            f.state.selectTab(f.web.id)
            #expect(f.state.shownChild[f.bot.id] == "t3")
            f.state.focusPane(f.bot.id)
            #expect(f.state.shownChild[f.bot.id] == "t3")
            #expect(!f.state.isTabOnScreen(f.bot.id))

            // The chip's click: the Bot's own terminal, focused and on screen.
            f.state.selectTab(f.web.id)
            f.state.showOwnTerminal(f.bot.id)
            #expect(f.state.shownChild[f.bot.id] == nil)
            #expect(f.state.selectedTab?.id == f.bot.id)
            #expect(f.state.isTabOnScreen(f.bot.id))
            // The web tab's chip does what it always did.
            f.state.showOwnTerminal(f.web.id)
            #expect(f.state.selectedTab?.id == f.web.id)
            #expect(f.state.isTabOnScreen(f.bot.id))
        }

        @Test func onlyATabsOwnChildCanBeShown() throws {
            let f = try makeFixture()
            defer { tearDown(f) }
            feedBot(f)
            f.state.showChild("t3", under: f.plain.id)   // another tab's child
            f.state.showChild("t2", under: f.bot.id)     // the mailbox is not a row
            f.state.showChild("t99", under: f.bot.id)    // no such terminal
            f.state.showChild("t3", under: f.web.id)     // not a terminal tab
            #expect(f.state.shownChild.isEmpty)
            #expect(f.state.selectedTab?.id == f.web.id)
            #expect(f.state.terminals.existingChildSession("t3") == nil)
        }

        @Test func aChildThatEndsGivesThePaneBack() throws {
            let f = try makeFixture()
            defer { tearDown(f) }
            feedBot(f)
            f.state.showChild("t3", under: f.bot.id)
            f.state.herdr.feed(line: event("finished", "t3"))
            // Its view is let go, but the tab's own terminal does not take the pane (and the
            // keyboard) back by itself: the owner may be typing to the worker. The pane says
            // it has ended, and the tab still doesn't count as on screen.
            #expect(f.state.terminals.existingChildSession("t3") == nil)
            #expect(f.state.shownChild[f.bot.id] == "t3")
            #expect(!f.state.isTabOnScreen(f.bot.id))
            // The owner goes back: ⌘W, or the button.
            f.state.closeTabCommand()
            #expect(f.state.shownChild[f.bot.id] == nil)
            #expect(f.state.space(f.space.id)?.tab(f.bot.id) != nil)

            // The same when its `hc attach` reports it gone before the watcher says so.
            f.state.showChild("t4", under: f.bot.id)
            f.state.herdrChildGone("t4")
            #expect(f.state.terminals.existingChildSession("t4") == nil)
            #expect(f.state.shownChild[f.bot.id] == "t4")
            f.state.showOwnTerminal(f.bot.id)

            // The listener going away is not every terminal ending: rows go, a shown view stays.
            f.state.showChild("t5", under: f.bot.id)
            f.state.herdr.stop()
            #expect(f.state.herdr.children(of: f.bot.id) == .none)
            #expect(f.state.terminals.existingChildSession("t5") != nil)
            #expect(f.state.shownChild[f.bot.id] == "t5")
        }

        @Test func closeTabCommandGoesBackBeforeItCloses() throws {
            let f = try makeFixture()
            defer { tearDown(f) }
            feedBot(f)
            f.state.showChild("t3", under: f.bot.id)
            f.state.closeTabCommand()
            #expect(f.state.shownChild[f.bot.id] == nil)
            #expect(f.state.space(f.space.id)?.tab(f.bot.id) != nil)
        }

        @Test func theTabIsNotOnScreenWhileAChildIsShown() throws {
            let f = try makeFixture()
            defer { tearDown(f) }
            feedBot(f)
            f.state.selectTab(f.bot.id)
            #expect(f.state.isTabOnScreen(f.bot.id))
            f.state.showChild("t3", under: f.bot.id)
            #expect(!f.state.isTabOnScreen(f.bot.id))

            // The Bot asks something behind its worker: an entry, as for any hidden tab.
            let blocked = TerminalSignal.status([
                StatusRecord(id: "", state: .blocked, kind: .question, app: "claude-code", message: "Which database?"),
            ])
            f.state.inbox.terminalSignal(blocked, tabID: f.bot.id, spaceID: f.space.id, foregroundProgram: "claude")
            #expect(f.state.inbox.inbox.visible.count == 1)

            // Going to another child is not going to the Bot: the entry stays.
            f.state.showChild("t4", under: f.bot.id)
            #expect(f.state.inbox.inbox.visible.count == 1)

            // "Go to terminal" shows the Bot's own terminal and that does count.
            let entry = try #require(f.state.inbox.inbox.visible.first)
            f.state.inbox.goTo(entry)
            #expect(f.state.shownChild[f.bot.id] == nil)
            #expect(f.state.isTabOnScreen(f.bot.id))
            #expect(f.state.inbox.inbox.visible.isEmpty)
        }

        @Test func closingATabWithChildrenAsks() throws {
            let f = try makeFixture()
            defer { tearDown(f) }
            feedBot(f)
            let children = f.state.herdr.children(of: f.bot.id)
            #expect(children.closeWarning(program: nil) == "It has 4 terminals under it. Most end with it.")
            #expect(children.closeWarning(program: "hermes")
                == "“hermes” is still running in it and will be stopped. It has 4 terminals under it. Most end with it.")
            #expect(HerdrChildren(rows: [], more: 0, liveCount: 1, needsYou: false).closeWarning(program: nil)
                == "It has 1 terminal under it, which most likely ends with it.")
            #expect(HerdrChildren.none.closeWarning(program: "vim") == "“vim” is still running in it and will be stopped.")
            #expect(HerdrChildren.none.closeWarning(program: nil) == nil)

            // Closed without the question (as `exit` in the shell does): the shown child is forgotten.
            f.state.showChild("t3", under: f.bot.id)
            f.state.closeTab(f.bot.id, confirmIfBusy: false)
            #expect(f.state.shownChild[f.bot.id] == nil)
            #expect(f.state.space(f.space.id)?.tab(f.bot.id) == nil)
        }

        @Test func nothingAboutChildrenIsSaved() throws {
            let f = try makeFixture()
            defer { tearDown(f) }
            f.state.flushSaves()
            let file = Paths(root: f.root).spaceFile(f.space.slug)
            let before = try Data(contentsOf: file)
            feedBot(f)
            f.state.herdr.collapsed.insert(f.bot.id)
            f.state.herdr.feed(line: event("status", "t3", ["status": ["state": "done"]]))
            f.state.flushSaves()
            let text = String(decoding: try Data(contentsOf: file), as: UTF8.self)
            #expect(!text.contains("plat135") && !text.contains("t3"))
            // Selecting the tab is saved as always; the child shown in it is not.
            f.state.showChild("t3", under: f.bot.id)
            f.state.flushSaves()
            let after = String(decoding: try Data(contentsOf: file), as: UTF8.self)
            #expect(!after.contains("plat135") && !after.contains("shownChild"))
            #expect(before.count > 0)
        }

        @Test func theListenerRunsOnlyWhereItMay() {
            #expect(HerdrWatcher.mayRun(herdrOn: true, hasTerminalTab: true, environment: [:]))
            #expect(!HerdrWatcher.mayRun(herdrOn: false, hasTerminalTab: true, environment: [:]))
            #expect(!HerdrWatcher.mayRun(herdrOn: true, hasTerminalTab: false, environment: [:]))
            // A test or development copy never lists the owner's real terminals.
            #expect(!HerdrWatcher.mayRun(herdrOn: true, hasTerminalTab: true, environment: ["SINGULARITY_HOME": "/private/tmp/x"]))
            #expect(HerdrWatcher.mayRun(herdrOn: true, hasTerminalTab: true,
                                        environment: ["SINGULARITY_HOME": "/private/tmp/x", "HC_SESSION": "trial"]))
        }

        @Test func noAgentToolSeesAChild() async throws {
            let f = try makeFixture()
            defer { tearDown(f) }
            let before = f.state.space(f.space.id)?.tabs.map(\.id)
            feedBot(f)
            f.state.showChild("t3", under: f.bot.id)
            // Children are not tabs: the Space's tab list, which every agent tool works from, is as it was.
            #expect(f.state.space(f.space.id)?.tabs.map(\.id) == before)
        }

        /// The rows and the pane draw, off screen, in a window that never becomes key.
        @Test func theRowsAndThePaneDraw() async throws {
            let f = try makeFixture()
            defer { tearDown(f) }
            feedBot(f)
            f.state.showChild("t4", under: f.bot.id)
            let space = try #require(f.state.space(f.space.id))
            let bot = try #require(space.tab(f.bot.id))
            let rows = TabWithChildrenRow(tab: bot, space: space, children: f.state.herdr.children(of: bot.id))
                .padding(12)
            #expect(try await drawsSomething(rows.environment(f.state), size: NSSize(width: 280, height: 140), name: "rows"))
            // The real sidebar and window, with the Bot's tab selected and a child shown.
            #expect(try await drawsSomething(SidebarView().environment(f.state), size: NSSize(width: 270, height: 420), name: "sidebar"))
            #expect(try await drawsSomething(MainView().environment(f.state), size: NSSize(width: 900, height: 480), name: "main"))
            f.state.herdr.collapsed.insert(bot.id)
            #expect(try await drawsSomething(SidebarView().environment(f.state), size: NSSize(width: 270, height: 420), name: "sidebar-folded"))
            f.state.herdr.collapsed.remove(bot.id)
            let pane = TabContentView(tab: bot)
            #expect(try await drawsSomething(pane.environment(f.state), size: NSSize(width: 480, height: 300), name: "pane"))
            f.state.herdr.feed(line: event("finished", "t4"))
            #expect(try await drawsSomething(TabContentView(tab: bot).environment(f.state), size: NSSize(width: 480, height: 300), name: "pane-ended"))
        }

        private func drawsSomething(_ view: some View, size: NSSize, name: String) async throws -> Bool {
            let window = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: size.width, height: size.height),
                                  styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height)
                .background(Color(nsColor: .windowBackgroundColor)))
            window.contentView = host
            window.orderFront(nil) // in front of nothing on screen; never made key or active
            defer { window.orderOut(nil) }
            try await Task.sleep(for: .milliseconds(300))
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return false }
            host.cacheDisplay(in: host.bounds, to: rep)
            // `SG_SNAPSHOT_DIR=<folder>` keeps the pictures, to look at by hand.
            if let folder = ProcessInfo.processInfo.environment["SG_SNAPSHOT_DIR"], let png = rep.representation(using: .png, properties: [:]) {
                try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
                try png.write(to: URL(filePath: folder).appending(path: "herdr-\(name).png"))
            }
            var colours = Set<UInt32>()
            for x in stride(from: 0, to: rep.pixelsWide, by: 4) {
                for y in stride(from: 0, to: rep.pixelsHigh, by: 4) {
                    guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                    colours.insert(UInt32(c.redComponent * 255) << 16 | UInt32(c.greenComponent * 255) << 8 | UInt32(c.blueComponent * 255))
                }
            }
            return colours.count > 2
        }
    }
}
