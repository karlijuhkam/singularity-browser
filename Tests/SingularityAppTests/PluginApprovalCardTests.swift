import AppKit
import Foundation
import MCP
import SwiftUI
import Testing
import WebKit
@testable import Singularity
import SingularityCore

private let repoRoot = URL(filePath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
private let bunPath = repoRoot.appending(path: "Vendor/bun/bun")
private let hostScript = repoRoot.appending(path: "Resources/plugin-host/host.ts")
private let hasBun = FileManager.default.isExecutableFile(atPath: bunPath.path)

extension AppTests {
/// Approvals of a plugin's own connection, answered in the plugin's page area: the inbox panel and
/// banners stay away while that page is on screen; the cards in the page share the inbox's click
/// lock and never take the keyboard; a cancelled call withdraws its approval (for every caller); a
/// Space switched off for the plugin denies its approvals there; and the strip for a Space the
/// plugin can't see.
///
/// No test here makes a window key or activates the app.
@MainActor
@Suite(.serialized) struct PluginApprovalCardTests {
    static let pluginID = "assistant"

    /// An `AgentApprovals` wired to its own `InboxCenter`, as `AppState` wires them, with the inbox
    /// panel on an off-screen window.
    @MainActor final class Rig {
        let approvals = AgentApprovals()
        let center = InboxCenter()
        let window: NSWindow
        var arrivals: [InboxEntry] = []
        var attention = 0
        var active: Bool
        var pageOnScreen: Set<String> = []
        var skew: TimeInterval = 0

        init(active: Bool) {
            MainRunLoopGuard.start
            self.active = active
            window = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: 900, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.orderFront(nil)
            center.now = { [unowned self] in Date().addingTimeInterval(self.skew) }
            center.appIsActive = { [unowned self] in self.active }
            center.windowIsKey = { false }
            center.onArrival = { [unowned self] in self.arrivals.append($0) }
            center.onChange = {}
            center.requestAttention = { [unowned self] in self.attention += 1 }
            center.pluginPageOnScreen = { [unowned self] in self.pageOnScreen.contains($0) }
            center.panelController.parentWindow = { [window] in window }
            // Never `makeKey`, even for a panel the owner opened.
            center.panelController.appIsActive = { false }
            approvals.presenter = { [center] in await center.requestApproval($0) }
        }

        func tearDown() {
            center.denyAllApprovals()
            center.closePanel()
            window.close()
        }

        func passTheLockout() { skew += InboxCenter.answerLockout + 0.1 }

        var waiting: [InboxEntry] {
            center.inbox.visible.filter { if case .approval = $0.kind { true } else { false } }
        }

        func check(pluginID: String?, space: Space = PluginApprovalCardTests.space) -> Task<AgentApprovals.Outcome, Never> {
            var request = AgentApprovals.Request(actor: pluginID == nil ? "Claude Code" : "Assistant", action: "click",
                                                 detail: "[2] button \"Buy\"", url: "https://example.com/",
                                                 spaceName: space.name, tabTitle: "Shop", text: nil)
            request.pluginID = pluginID
            let context = AgentActionContext(kind: .click, pageOrigin: "https://example.com")
            return Task { @MainActor in await approvals.check(context, space: space, request: request) }
        }

        @discardableResult
        func waitForEntry(count: Int = 1) async throws -> InboxEntry {
            try await waitUntil("\(count) approval entries") { waiting.count >= count }
            return try #require(waiting.max { $0.arrived < $1.arrived })
        }
    }

    static let space: Space = {
        var space = Space(name: "Work", slug: "work", colorHex: "#5E81F4")
        space.agentPolicy = .ask
        return space
    }()

    // MARK: Where the approval is announced

    @Test func anApprovalOfAPluginWhosePageIsOnScreenOpensNothing() async throws {
        let rig = Rig(active: true)
        defer { rig.tearDown() }
        rig.pageOnScreen = [Self.pluginID]
        let answer = rig.check(pluginID: Self.pluginID)
        let entry = try await rig.waitForEntry()
        #expect(entry.pluginID == Self.pluginID)
        // In the list and counted, but no panel, no banner, no Dock bounce.
        #expect(rig.center.inbox.count == 1)
        #expect(!rig.center.isPanelShown)
        #expect(rig.arrivals.isEmpty)
        #expect(rig.attention == 0)
        #expect(rig.center.approvals(forPlugin: Self.pluginID).map(\.id) == [entry.id])
        #expect(rig.center.approvals(forPlugin: "other").isEmpty)
        rig.center.decideApproval(entry.id, .denied)
        #expect(await answer.value.logValue == "denied")
    }

    @Test func whenThePageIsNotOnScreenItIsAsToday() async throws {
        // Active: the panel opens by itself, without a banner.
        let rig = Rig(active: true)
        defer { rig.tearDown() }
        rig.pageOnScreen = ["other"]
        let first = rig.check(pluginID: Self.pluginID)
        let entry = try await rig.waitForEntry()
        #expect(rig.center.isPanelShown)
        #expect(rig.arrivals.isEmpty)
        rig.center.decideApproval(entry.id, .denied)
        _ = await first.value
        rig.center.closePanel()

        // In the background: a banner and a bounce.
        rig.active = false
        let second = rig.check(pluginID: Self.pluginID)
        let next = try await rig.waitForEntry()
        #expect(!rig.center.isPanelShown)
        #expect(rig.arrivals.map(\.id) == [next.id])
        #expect(rig.attention == 1)
        rig.center.decideApproval(next.id, .denied)
        _ = await second.value
    }

    @Test func anApprovalWithoutAPluginIsAsToday() async throws {
        let rig = Rig(active: false)
        defer { rig.tearDown() }
        rig.pageOnScreen = [Self.pluginID, "other"]
        let answer = rig.check(pluginID: nil)
        let entry = try await rig.waitForEntry()
        #expect(entry.pluginID == nil)
        #expect(rig.arrivals.map(\.id) == [entry.id])
        #expect(rig.attention == 1)
        #expect(rig.center.approvals(forPlugin: Self.pluginID).isEmpty)
        rig.center.decideApproval(entry.id, .denied)
        _ = await answer.value
    }

    // MARK: Answers from a card

    @Test func aCardAnswersOnlyAfterTheLock() async throws {
        let rig = Rig(active: true)
        defer { rig.tearDown() }
        rig.pageOnScreen = [Self.pluginID]
        let answer = rig.check(pluginID: Self.pluginID)
        let entry = try await rig.waitForEntry()
        // The card just appeared: a click now counts for nothing.
        rig.center.perform(.decideApproval(entry.id, .approved))
        #expect(rig.waiting.map(\.id) == [entry.id])
        rig.passTheLockout()
        rig.center.perform(.decideApproval(entry.id, .approved))
        #expect(await answer.value.logValue == "approved")
        #expect(rig.waiting.isEmpty)
    }

    @Test func aSecondCardRestartsTheLock() async throws {
        let rig = Rig(active: true)
        defer { rig.tearDown() }
        rig.pageOnScreen = [Self.pluginID]
        let first = rig.check(pluginID: Self.pluginID)
        let firstEntry = try await rig.waitForEntry()
        rig.passTheLockout()
        let second = rig.check(pluginID: Self.pluginID)
        try await rig.waitForEntry(count: 2)
        // A card was added: the buttons are locked again.
        rig.center.answerFromCard(firstEntry.id, .approved)
        #expect(rig.waiting.count == 2)
        rig.passTheLockout()
        rig.center.answerFromCard(firstEntry.id, .denied)
        #expect(await first.value.logValue == "denied")
        rig.center.denyAllApprovals()
        _ = await second.value
    }

    // MARK: Withdrawing

    @Test func withdrawingResumesTheWaiterWithCancelled() async throws {
        let rig = Rig(active: false)
        defer { rig.tearDown() }
        let answer = rig.check(pluginID: Self.pluginID)
        let entry = try await rig.waitForEntry()
        rig.center.withdrawApproval(entry.id)
        let outcome = await answer.value
        #expect(outcome.logValue == "cancelled")
        #expect(!outcome.isAllowed)
        #expect(outcome.refusal == "The request was withdrawn.")
        #expect(rig.waiting.isEmpty)
        // Once only: a late answer or a second withdraw finds nothing.
        rig.center.withdrawApproval(entry.id)
        rig.center.decideApproval(entry.id, .approved)
    }

    @Test func cancellingTheCallingTaskWithdraws() async throws {
        let rig = Rig(active: false)
        defer { rig.tearDown() }
        let answer = rig.check(pluginID: nil)
        try await rig.waitForEntry()
        answer.cancel()
        let outcome = await answer.value
        #expect(outcome.logValue == "cancelled")
        try await waitUntil("the entry to go") { rig.waiting.isEmpty }
    }

    @Test func aCallAlreadyCancelledAsksNothing() async throws {
        let rig = Rig(active: false)
        defer { rig.tearDown() }
        let started = Flag()
        var request = AgentApprovals.Request(actor: "Claude Code", action: "click", detail: "x", url: nil,
                                             spaceName: "Work", tabTitle: nil, text: nil)
        request.pluginID = nil
        let task = Task { @MainActor in
            while !started.value { await Task.yield() }
            return await rig.approvals.check(AgentActionContext(kind: .click, pageOrigin: "https://example.com"),
                                             space: Self.space, request: request)
        }
        task.cancel()
        started.value = true
        #expect(await task.value.logValue == "cancelled")
        #expect(rig.center.inbox.entries.isEmpty)
        #expect(rig.arrivals.isEmpty)
    }

    @MainActor final class Flag { var value = false }
    @MainActor final class Clock { var skew: TimeInterval = 0 }

    /// Through the real agent socket, for an outside agent: `notifications/cancelled` for the call,
    /// and the connection closing, each withdraw the call's waiting approval.
    @Test(.timeLimit(.minutes(1))) func aCancelledOrClosedCallWithdrawsItsApproval() async throws {
        MainRunLoopGuard.start
        let root = TestAppState.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SpaceStore(paths: Paths(root: root))
        var space = Space(name: "Work", slug: "work", colorHex: "#5E81F4")
        space.agentsEnabled = true
        space.agentPolicy = .ask
        try store.save(space)
        try store.save(AppStateFile(spaceOrder: [space.id], selectedSpaceID: space.id))
        let state = TestAppState.make(root: root)
        defer { TestAppState.shutDown(state) }
        state.inbox.appIsActive = { false }
        state.inbox.onArrival = { _ in }
        state.inbox.requestAttention = {}

        // Cancelled by the client.
        let client = try SocketClient(path: state.paths.mcpSocket.path)
        defer { client.close() }
        try await client.initialize()
        try client.send(["jsonrpc": "2.0", "id": 7, "method": "tools/call",
                         "params": ["name": "work.open", "arguments": ["url": "https://example.com/"]]])
        try await waitUntil("the approval", limit: .seconds(10)) { state.inbox.inbox.count == 1 }
        try client.send(["jsonrpc": "2.0", "method": "notifications/cancelled", "params": ["requestId": 7, "reason": "Stop"]])
        try await waitUntil("the approval to be withdrawn", limit: .seconds(10)) { state.inbox.inbox.count == 0 }
        #expect(state.space(space.id)?.tabs.isEmpty == true)

        // The connection closed.
        try client.send(["jsonrpc": "2.0", "id": 8, "method": "tools/call",
                         "params": ["name": "work.open", "arguments": ["url": "https://example.org/"]]])
        try await waitUntil("the second approval", limit: .seconds(10)) { state.inbox.inbox.count == 1 }
        client.close()
        try await waitUntil("the second approval to be withdrawn", limit: .seconds(10)) { state.inbox.inbox.count == 0 }
        #expect(state.space(space.id)?.tabs.isEmpty == true)
    }

    // MARK: A Space switched off

    @Test func switchingTheSpaceOffDeniesThatPluginsApprovalsThere() async throws {
        MainRunLoopGuard.start
        let root = TestAppState.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = Paths(root: root)
        let store = SpaceStore(paths: paths)
        var work = Space(name: "Work", slug: "work", colorHex: "#5E81F4")
        work.agentPolicy = .ask
        var home = Space(name: "Home", slug: "home", colorHex: "#E0A030")
        home.agentPolicy = .ask
        try store.save(work)
        try store.save(home)
        try store.save(AppStateFile(spaceOrder: [work.id, home.id], selectedSpaceID: work.id))
        // The plugin's approval, switched on for both Spaces (no plugin folder is needed for that).
        let approval = PluginApproval(fingerprint: "x", permissions: .init(), commandPaths: [:],
                                      enabledSpaces: [work.id, home.id], developmentMode: false, approvedAt: Date(),
                                      fileHashes: [:])
        try PluginStateStore(file: paths.pluginStateFile).save([Self.pluginID: approval])
        let state = TestAppState.make(root: root)
        defer { TestAppState.shutDown(state) }
        state.inbox.appIsActive = { false }
        state.inbox.onArrival = { _ in }
        state.inbox.requestAttention = {}

        func ask(_ space: Space, pluginID: String?) -> Task<AgentApprovals.Outcome, Never> {
            var request = AgentApprovals.Request(actor: "Assistant", action: "click", detail: "x", url: nil,
                                                 spaceName: space.name, tabTitle: nil, text: nil)
            request.pluginID = pluginID
            return Task { @MainActor in
                await state.approvals.check(AgentActionContext(kind: .click, pageOrigin: "https://example.com"),
                                            space: space, request: request)
            }
        }
        let inWork = ask(work, pluginID: Self.pluginID)
        try await waitUntil("1") { state.inbox.inbox.count == 1 }
        let inHome = ask(home, pluginID: Self.pluginID)
        try await waitUntil("2") { state.inbox.inbox.count == 2 }
        let agentInWork = ask(work, pluginID: nil)
        try await waitUntil("3") { state.inbox.inbox.count == 3 }

        state.plugins.setEnabled(Self.pluginID, space: work.id, false)
        #expect(await inWork.value.logValue == "denied")
        #expect(state.inbox.inbox.count == 2)
        // Its approval in another Space and an outside agent's in this one wait on.
        #expect(Set(state.inbox.inbox.visible.map(\.spaceID)) == [work.id, home.id])
        // Switching on does nothing to them.
        state.plugins.setEnabled(Self.pluginID, space: work.id, true)
        #expect(state.inbox.inbox.count == 2)
        state.inbox.denyAllApprovals()
        _ = await inHome.value
        _ = await agentInWork.value
    }

    // MARK: Where the page counts as shown

    /// The panel showing the plugin (when drawn), or a tab of it among the visible tabs; never
    /// under the welcome flow.
    @Test func wherePageCountsAsShown() throws {
        let f = try PageFixture()
        defer { f.tearDown() }
        let id = Self.pluginID
        let wide = 1600.0
        #expect(!f.state.pluginPageIsShown(id, windowWidth: wide))

        f.state.updateSettings { $0.pluginPanel = id }
        #expect(f.state.pluginPageIsShown(id, windowWidth: wide))
        #expect(!f.state.pluginPageIsShown("other", windowWidth: wide))
        // A window too narrow to draw the panel.
        #expect(!f.state.pluginPageIsShown(id, windowWidth: 400))

        // As a tab: shown while selected, not behind another tab.
        f.state.openPluginPageAsTab(id)
        #expect(f.state.settings.pluginPanel == nil)
        #expect(f.state.pluginPageIsShown(id, windowWidth: wide))
        f.state.openInNewTab(URL(string: "https://a.example/")!)
        #expect(!f.state.pluginPageIsShown(id, windowWidth: wide))

        // The welcome flow covers everything.
        f.state.updateSettings { $0.pluginPanel = "other" }
        #expect(f.state.pluginPageIsShown("other", windowWidth: wide))
        f.state.showWelcome()
        #expect(!f.state.pluginPageIsShown("other", windowWidth: wide))
    }

    // MARK: The cards in the page area

    /// Four waiting: three cards, oldest first, and a line for the fourth. Other plugins' and
    /// outside agents' approvals are not drawn here.
    @Test func threeCardsAndTheRestInTheInbox() async throws {
        let f = try PageFixture()
        defer { f.tearDown() }
        var inbox = Inbox()
        let now = Date()
        var ids: [UUID] = []
        for i in 0..<4 {
            ids.append(inbox.addApproval(f.approval(), spaceID: f.spaceID, tabID: nil, deadline: now.addingTimeInterval(120),
                                         now: now.addingTimeInterval(Double(i)), pluginID: Self.pluginID).id)
        }
        _ = inbox.addApproval(f.approval(), spaceID: f.spaceID, tabID: nil, deadline: now.addingTimeInterval(120), now: now,
                              pluginID: "other")
        _ = inbox.addApproval(f.approval(), spaceID: f.spaceID, tabID: nil, deadline: now.addingTimeInterval(120), now: now)
        f.state.inbox.replaceInboxForTesting(inbox)

        let content = f.state.pluginPageCards(Self.pluginID, showsStrip: true)
        #expect(content.cards.map(\.id) == Array(ids.prefix(3)))
        #expect(content.moreText == "and 1 more in the inbox")
        // With cards waiting, no strip.
        #expect(content.strip == nil)

        // The view draws them below the page, which is made shorter for them.
        let webView = WKWebView()
        let host = f.show(webView: webView)
        try await waitUntil("the cards to be laid out") {
            host.layoutSubtreeIfNeeded()
            return webView.frame.height > 0 && webView.frame.height < host.bounds.height - 300
        }
        #expect(abs(webView.frame.maxY - host.bounds.maxY) < 0.5 || abs(webView.frame.minY) < 0.5)

        // Fewer: no line.
        var three = Inbox()
        for i in 0..<3 {
            _ = three.addApproval(f.approval(), spaceID: f.spaceID, tabID: nil, deadline: now.addingTimeInterval(120),
                                  now: now.addingTimeInterval(Double(i)), pluginID: Self.pluginID)
        }
        f.state.inbox.replaceInboxForTesting(three)
        #expect(f.state.pluginPageCards(Self.pluginID).moreText == nil)
    }

    /// The chat input (the web view) keeps the keyboard when a card appears and when it goes; no
    /// button of a card is in the window's key view loop (the inbox panel's are: the probe works),
    /// none is a default button, and Return or Space at the window answers nothing.
    @Test func aCardNeverTakesTheKeyboard() async throws {
        let f = try PageFixture()
        defer { f.tearDown() }
        let webView = WKWebView()
        let host = f.show(webView: webView)
        host.layoutSubtreeIfNeeded()
        let fullHeight = webView.frame.height
        #expect(fullHeight > 600)
        #expect(f.window.makeFirstResponder(webView))
        let isWebView = { (responder: NSResponder?) -> Bool in
            guard let view = responder as? NSView else { return false }
            return view === webView || view.isDescendant(of: webView)
        }
        #expect(isWebView(f.window.firstResponder))

        // A real request, so a button pressed by a key would answer it.
        let clock = Clock()
        f.state.inbox.now = { Date().addingTimeInterval(clock.skew) }
        f.state.inbox.pluginPageOnScreen = { $0 == Self.pluginID }
        f.state.inbox.requestAttention = {}
        var request = AgentApprovals.Request(actor: "Assistant", action: "click", detail: "[2] button \"Buy\"",
                                             url: "https://example.com/", spaceName: "Work", tabTitle: "Shop", text: nil)
        request.pluginID = Self.pluginID
        let space = try #require(f.state.space(f.spaceID))
        let answer = Task { @MainActor in
            await f.state.approvals.check(AgentActionContext(kind: .click, pageOrigin: "https://example.com"),
                                          space: space, request: request)
        }
        try await waitUntil("the card to appear") {
            host.layoutSubtreeIfNeeded()
            return webView.frame.height < fullHeight - 40
        }
        // Let SwiftUI finish building the card's views (and their key view proxies, if any).
        try await Task.sleep(for: .milliseconds(300))
        host.layoutSubtreeIfNeeded()
        #expect(isWebView(f.window.firstResponder))
        #expect(f.window.defaultButtonCell == nil)

        // Nothing in the card can become first responder. Built afresh with the card already
        // there (SwiftUI makes its key view stand-ins when a view is first laid out in a window),
        // beside the inbox panel's list with the same card, whose buttons can (the probe works).
        for (takesKeyboard, root) in [(false, AnyView(PluginPageCards(pluginID: Self.pluginID, showsStrip: false)
                                                         .environment(f.state))),
                                      (true, AnyView(InboxListView(center: f.state.inbox, onAction: { _ in })))] {
            let other = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: 330, height: 400),
                                 styleMask: [.titled], backing: .buffered, defer: false)
            other.isReleasedWhenClosed = false
            let view = NSHostingView(rootView: root)
            view.sizingOptions = []
            other.contentView = view
            other.orderFront(nil)
            defer { other.close() }
            view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(300))
            view.layoutSubtreeIfNeeded()
            let takers = keyboardTakers(in: view)
            #expect(takers.isEmpty != takesKeyboard, "\(takesKeyboard ? "inbox list" : "page cards"): \(takers)")
            #expect(other.defaultButtonCell == nil)
        }

        // Past the click lock, so a press would count: Return and Space at the window (and at the
        // web view, which has the keyboard) answer nothing.
        clock.skew = InboxCenter.answerLockout + 0.1
        let before = f.state.inbox.inbox.visible
        #expect(before.count == 1)
        for (key, code) in [("\r", UInt16(36)), (" ", UInt16(49))] {
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                      windowNumber: f.window.windowNumber, context: nil, characters: key,
                                                      charactersIgnoringModifiers: key, isARepeat: false, keyCode: code))
            _ = f.window.performKeyEquivalent(with: event)
            f.window.sendEvent(event)
        }
        try await Task.sleep(for: .milliseconds(200))
        #expect(f.state.inbox.inbox.visible == before)
        #expect(isWebView(f.window.firstResponder))

        // The card going away (answered) doesn't move the keyboard either.
        f.state.inbox.decideApproval(try #require(before.first?.id), .denied)
        #expect(await answer.value.logValue == "denied")
        try await waitUntil("the card to go") {
            host.layoutSubtreeIfNeeded()
            return abs(webView.frame.height - fullHeight) < 0.5
        }
        #expect(isWebView(f.window.firstResponder))
    }

    /// The Space in front is not switched on for a plugin that reaches Spaces: one line and a
    /// button that switches it on.
    @Test(.timeLimit(.minutes(1)), .enabled(if: hasBun, "Vendor/bun/bun is missing (run scripts/fetch-bun.sh)"))
    func theStripLetsThePluginUseTheSpace() async throws {
        let ws = try CardWorkspace()
        defer { ws.remove() }
        try ws.approve()
        let manager = PluginManager(paths: ws.paths, runtime: bunPath, host: hostScript,
                                    programs: .live(environment: [:], loginPath: { "/usr/bin:/bin" }))
        let appRoot = TestAppState.makeRoot()
        let state = TestAppState.make(root: appRoot, plugins: manager)
        defer {
            TestAppState.shutDown(state)
            manager.terminateAll()
            try? FileManager.default.removeItem(at: appRoot)
        }
        state.closeWelcome()
        manager.start()
        try await waitUntil("the plugin to run", limit: .seconds(20)) { manager.plugin(CardWorkspace.id)?.runState == .running }
        // A Space without a tab: the strip too.
        #expect(state.selectedSpace?.tabs.isEmpty == true)
        #expect(state.pluginFront(CardWorkspace.id) == .hidden(.spaceOff))
        #expect(state.pluginPageCards(CardWorkspace.id, showsStrip: true).strip != nil)
        state.openInNewTab(URL(string: "https://a.example/")!)
        let space = try #require(state.selectedSpace)

        #expect(state.pluginFront(CardWorkspace.id) == .hidden(.spaceOff))
        let strip = try #require(state.pluginPageCards(CardWorkspace.id, showsStrip: true).strip)
        #expect(strip.text == "Card Fixture can't see \(space.name)")
        #expect(strip.buttonTitle == "Let it use \(space.name)")
        // Not without the page.
        #expect(state.pluginPageCards(CardWorkspace.id, showsStrip: false).strip == nil)

        // The strip's button never takes the keyboard either.
        let window = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: 420, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = NSHostingView(rootView: PluginPageCards(pluginID: CardWorkspace.id, showsStrip: true).environment(state))
        view.sizingOptions = []
        window.contentView = view
        window.orderFront(nil)
        defer { window.close() }
        view.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        view.layoutSubtreeIfNeeded()
        // It is drawn: something to measure.
        let measured = NSHostingController(rootView: PluginPageCards(pluginID: CardWorkspace.id, showsStrip: true).environment(state))
            .sizeThatFits(in: CGSize(width: 420, height: 1000))
        #expect(measured.height > 10 && measured.height < 100)
        #expect(keyboardTakers(in: view).isEmpty)
        #expect(window.defaultButtonCell == nil)

        state.letPluginUseSpace(strip)
        #expect(manager.plugin(CardWorkspace.id)?.approval?.enabledSpaces.contains(space.id) == true)
        #expect(state.pluginPageCards(CardWorkspace.id, showsStrip: true).strip == nil)

        // A plugin that doesn't reach Spaces never gets one.
        manager.setEnabled(CardWorkspace.id, space: space.id, false)
        #expect(state.pluginPageCards(CardWorkspace.id, showsStrip: true).strip != nil)
        #expect(state.pluginPageCards("not-installed", showsStrip: true).strip == nil)
    }

    // MARK: A yes that comes too late

    /// The owner's Allow was handled just before the call's cancel took effect: the call must not
    /// act on it (`.cancelled`), whether the call asked from its own task or under a cancellation
    /// token (the navigation guard).
    @Test func anAllowJustBeforeTheCancelDoesNotAct() async throws {
        let rig = Rig(active: false)
        defer { rig.tearDown() }
        let answer = rig.check(pluginID: Self.pluginID)
        let entry = try await rig.waitForEntry()
        // In one main-actor turn: the answer resumes the waiting check, then the call is cancelled
        // before the check runs on.
        rig.center.decideApproval(entry.id, .approved)
        answer.cancel()
        #expect(await answer.value.logValue == "cancelled")

        // Under a token: cancelled after the yes, before the asking code runs on.
        let token = ApprovalCancellation()
        var request = AgentApprovals.Request(actor: "Assistant", action: "go to another site", detail: "https://x.example/",
                                             url: nil, spaceName: "Work", tabTitle: nil, text: nil)
        request.cancellation = token
        let guarded = Task { @MainActor in
            await rig.approvals.check(AgentActionContext(kind: .navigate, pageOrigin: "https://example.com",
                                                         targetOrigin: "https://x.example"),
                                      space: Self.space, request: request)
        }
        let second = try await rig.waitForEntry()
        rig.center.decideApproval(second.id, .approved)
        token.cancel()
        #expect(await guarded.value.logValue == "cancelled")
    }

    /// Cancelling the token withdraws what waits under it, and nothing more is asked under it.
    @Test func aCancelledTokenWithdrawsAndAsksNothingMore() async throws {
        let rig = Rig(active: false)
        defer { rig.tearDown() }
        let token = ApprovalCancellation()
        func ask() -> Task<AgentApprovals.Outcome, Never> {
            var request = AgentApprovals.Request(actor: "Assistant", action: "go to another site", detail: "https://x.example/",
                                                 url: nil, spaceName: "Work", tabTitle: nil, text: nil)
            request.cancellation = token
            return Task { @MainActor in
                await rig.approvals.check(AgentActionContext(kind: .navigate, pageOrigin: "https://example.com",
                                                             targetOrigin: "https://x.example"),
                                          space: Self.space, request: request)
            }
        }
        let first = ask()
        try await rig.waitForEntry()
        token.cancel()
        #expect(await first.value.logValue == "cancelled")
        #expect(rig.waiting.isEmpty)
        #expect(await ask().value.logValue == "cancelled")
        #expect(rig.center.inbox.entries.isEmpty)
    }

    // MARK: A stopped click

    /// A click whose navigation (to another site) waits for the owner, then the call is stopped:
    /// the call returns at once (no spinning), the navigation's entry is withdrawn and logged, and
    /// the page never moves, not even after a while.
    @Test(.timeLimit(.minutes(1))) func aStoppedClickNeverNavigates() async throws {
        MainRunLoopGuard.start
        let server = try TitleFixtureServer.start()
        defer { server.stop() }
        let root = TestAppState.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SpaceStore(paths: Paths(root: root))
        var space = Space(name: "Work", slug: "work", colorHex: "#5E81F4")
        space.agentsEnabled = true
        space.agentPolicy = .ask
        let tab = BrowserTab.web(server.url("/go"))
        space.append(tab)
        space.selectedTabID = tab.id
        try store.save(space)
        try store.save(AppStateFile(spaceOrder: [space.id], selectedSpaceID: space.id))
        let state = TestAppState.make(root: root)
        defer { TestAppState.shutDown(state) }
        state.inbox.appIsActive = { false }
        state.inbox.onArrival = { _ in }
        state.inbox.requestAttention = {}
        let toolbox = AgentToolbox(state: state)
        let tabArgument = Value.string(tab.id.uuidString.lowercased())

        let page = await toolbox.call("work.read_page", arguments: ["tab_id": tabArgument], client: "test-agent", caller: .outside)
        let outline = page.content.compactMap { if case .text(let text, _, _) = $0 { text } else { nil } }.joined()
        let match = try #require(outline.firstMatch(of: /\[(\d+)\] button "Go"/), "no Go button in \(outline)")
        let ref = try #require(Int(match.1))
        let controller = try #require(state.web.existingController(tab.id))

        let click = Task { @MainActor in
            await toolbox.call("work.click", arguments: ["tab_id": tabArgument, "ref": .int(ref)], client: "test-agent", caller: .outside)
        }
        // The click itself asks first: allowed.
        try await waitUntil("the click's approval", limit: .seconds(10)) { state.inbox.inbox.count == 1 }
        let clickEntry = try #require(state.inbox.inbox.visible.first)
        state.inbox.decideApproval(clickEntry.id, .approved)
        // Then the page moves to another site: the guard asks.
        try await waitUntil("the navigation's approval", limit: .seconds(10)) {
            state.inbox.inbox.visible.contains { entry in
                if case .approval(let approval) = entry.kind { approval.action == "go to another site" } else { false }
            }
        }
        #expect(controller.pendingNavigationApprovals == 1)

        let stopped = ContinuousClock.now
        click.cancel()
        _ = await click.value
        #expect(ContinuousClock.now - stopped < .seconds(1), "the stopped call took \(ContinuousClock.now - stopped)")
        try await waitUntil("the navigation's approval to be withdrawn") { state.inbox.inbox.count == 0 }
        try await waitUntil("the guard to give up") { controller.pendingNavigationApprovals == 0 }
        // Nothing moves the page later.
        try await Task.sleep(for: .seconds(1))
        #expect(controller.webView.url?.host() == "127.0.0.1")
        #expect(controller.webView.url?.path() == "/go")
        let logged = AgentLogStore(file: state.paths.agentLogFile("work")).loadRecent()
        let clickLog = try #require(logged.last { $0.tool == "work.click" })
        #expect(clickLog.decision.contains("nav_cancelled"), "decision: \(clickLog.decision)")
    }

    /// `waitUntilLoaded` in a cancelled task returns at once, also in the middle of a load (a
    /// cancelled `Task.sleep` returns immediately, so a loop on it would spin the main actor).
    @Test(.timeLimit(.minutes(1))) func aCancelledWaitForALoadEndsAtOnce() async throws {
        MainRunLoopGuard.start
        let server = try TitleFixtureServer.start()
        defer { server.stop() }
        let f = try PageFixture()
        defer { f.tearDown() }
        let controller = WebTabController(tabID: UUID(), spaceID: f.spaceID, configuration: WKWebViewConfiguration(), state: nil)
        controller.load(server.url("/slow-titled?t=Slow"))
        try await waitUntil("the load to start") { controller.webView.isLoading }
        let wait = Task { @MainActor in
            let started = ContinuousClock.now
            await controller.waitUntilLoaded()
            return ContinuousClock.now - started
        }
        try await Task.sleep(for: .milliseconds(150))
        wait.cancel()
        let waited = await wait.value
        #expect(controller.webView.isLoading, "the load should still be going on")
        #expect(waited < .milliseconds(400), "waited \(waited)")
        // Already cancelled when called: returns at once.
        let early = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            let started = ContinuousClock.now
            await controller.waitUntilLoaded()
            return ContinuousClock.now - started
        }
        #expect(await early.value < .milliseconds(50))
        controller.webView.stopLoading()
    }

    // MARK: - Helpers

    /// A real `AppState` and an off-screen window that never becomes key, for the page area's layout.
    @MainActor final class PageFixture {
        let root = TestAppState.makeRoot()
        let state: AppState
        let spaceID: UUID
        let window: NSWindow

        init() throws {
            MainRunLoopGuard.start
            let store = SpaceStore(paths: Paths(root: root))
            let space = Space(name: "Work", slug: "work", colorHex: "#5E81F4")
            try store.save(space)
            try store.save(AppStateFile(spaceOrder: [space.id], selectedSpaceID: space.id))
            state = TestAppState.make(root: root)
            spaceID = space.id
            window = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: 420, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.orderFront(nil)
        }

        func approval() -> InboxApproval {
            InboxApproval(actor: "Assistant", action: "click", detail: "[2] button \"Buy\"", url: "https://example.com/",
                          tabTitle: "Shop", siteHost: "example.com")
        }

        /// The page area's layout with `webView` as the page.
        func show(webView: WKWebView) -> NSView {
            let host = NSHostingView(rootView: PluginPageAreaLayout(pluginID: PluginApprovalCardTests.pluginID, showsStrip: true) {
                WebViewBox(webView: webView)
            }.environment(state))
            // The window's size is the test's, not the content's.
            host.sizingOptions = []
            window.contentView = host
            return host
        }

        func tearDown() {
            window.contentView = nil
            window.close()
            TestAppState.shutDown(state)
            try? FileManager.default.removeItem(at: root)
        }
    }

    struct WebViewBox: NSViewRepresentable {
        let webView: WKWebView
        func makeNSView(context: Context) -> WKWebView { webView }
        func updateNSView(_ view: WKWebView, context: Context) {}
    }
}
}

/// What in `view` could take the keyboard: SwiftUI's stand-ins for its focusable controls in the
/// window's key view loop (a private class, `KeyViewProxy`), and AppKit buttons (`.link` style)
/// that accept first responder.
@MainActor
private func keyboardTakers(in view: NSView) -> [String] {
    var found: [String] = []
    func walk(_ view: NSView) {
        let name = String(describing: type(of: view))
        if name.contains("KeyViewProxy") { found.append(name) }
        if let button = view as? NSButton, button.acceptsFirstResponder { found.append("\(name) “\(button.title)”") }
        view.subviews.forEach(walk)
    }
    walk(view)
    return found
}

/// A data folder with one plugin that reaches Spaces (`frontTab`) and has a panel.
private struct CardWorkspace {
    static let id = "cardfix"
    let root: URL
    var paths: Paths { Paths(root: root) }
    var plugin: URL { paths.pluginsDirectory.appending(path: Self.id, directoryHint: .isDirectory) }

    init() throws {
        root = URL(filePath: "/private/tmp/sg-cf-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: plugin, withIntermediateDirectories: true)
        func write(_ path: String, _ text: String) throws { try Data(text.utf8).write(to: plugin.appending(path: path)) }
        try write("plugin.json", """
            {"id": "cardfix", "name": "Card Fixture", "version": "1.0.0", "description": "A test plugin.",
             "author": "Tests", "background": "background.ts",
             "panel": {"page": "panel.html", "title": "Card Fixture"},
             "permissions": {"frontTab": true}}
            """)
        try write("panel.html", "<!doctype html><html><head><title>x</title></head><body></body></html>")
        try write("background.ts", """
            import { singularity } from "singularity";
            singularity.onPageMessage(async () => null);
            """)
    }

    func approve() throws {
        let scan = PluginScan.scan(folder: plugin)
        guard let manifest = scan.validManifest, let snapshot = scan.snapshot else {
            throw NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "the fixture doesn't scan: \(scan.manifest)"])
        }
        let approval = PluginApproval(fingerprint: snapshot.fingerprint, permissions: manifest.permissions,
                                      commandPaths: [:], enabledSpaces: [],
                                      developmentMode: false, approvedAt: Date(), fileHashes: snapshot.fileHashes)
        try PluginStateStore(file: paths.pluginStateFile).save([Self.id: approval])
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

/// A plain MCP client on the agent socket (an outside agent: the test process).
private final class SocketClient: @unchecked Sendable {
    private let fd: Int32
    private let lock = NSLock()
    private var lines: [String] = []
    private var closed = false

    init(path: String) throws {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: path.utf8)
            buffer[path.utf8.count] = 0
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else {
            Darwin.close(fd)
            throw NSError(domain: "socket", code: 1, userInfo: [NSLocalizedDescriptionKey: "could not connect to \(path)"])
        }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        let fd = fd
        Thread.detachNewThread { [weak self] in
            var pending = Data()
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let count = read(fd, &buffer, buffer.count)
                if count <= 0 { return }
                pending.append(contentsOf: buffer[0..<count])
                while let newline = pending.firstIndex(of: 0x0A) {
                    let line = String(decoding: pending[pending.startIndex..<newline], as: UTF8.self)
                    self?.lock.withLock { self?.lines.append(line) }
                    pending.removeSubrange(pending.startIndex...newline)
                }
            }
        }
    }

    func send(_ message: [String: Any]) throws {
        let bytes = Array(try JSONSerialization.data(withJSONObject: message)) + [0x0A]
        let written = bytes.withUnsafeBytes { write(fd, $0.baseAddress, bytes.count) }
        guard written == bytes.count else { throw NSError(domain: "socket", code: 2) }
    }

    @MainActor
    func initialize() async throws {
        try send(["jsonrpc": "2.0", "id": 1, "method": "initialize",
                  "params": ["protocolVersion": "2025-03-26", "capabilities": [String: Any](),
                             "clientInfo": ["name": "test-agent", "version": "1.0"]]])
        try await waitUntil("the initialize answer", limit: .seconds(10)) {
            lock.withLock { lines.contains { $0.contains("\"id\":1") } }
        }
        try send(["jsonrpc": "2.0", "method": "notifications/initialized"])
    }

    func close() {
        let first = lock.withLock { () -> Bool in
            defer { closed = true }
            return !closed
        }
        guard first else { return }
        Darwin.shutdown(fd, SHUT_RDWR)
        Darwin.close(fd)
    }
}
