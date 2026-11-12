import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Singularity
import SingularityCore

extension AppTests {
/// The inbox panel on a real (off-screen) window: it never takes the keyboard by itself, has no
/// default button, closes on Esc / a click outside / "Go to terminal", and keeps its size in check.
///
/// No test here makes any window key: a key window of the test process could take the owner's
/// keyboard. The panel's controller is told the app is never active (`appIsActive`), so even
/// "taking focus" stops short of `makeKey`; what that leaves unchecked is in the task report.
@MainActor
@Suite(.serialized) struct InboxPanelTests {
    @MainActor struct Fixture {
        let root: URL
        let state: AppState
        let space: Space
        let window: NSWindow
        var center: InboxCenter { state.inbox }
        var controller: InboxPanelController { state.inbox.panelController }
    }

    private func makeFixture(windowHeight: CGFloat = 600) throws -> Fixture {
        MainRunLoopGuard.start
        let root = TestAppState.makeRoot()
        let store = SpaceStore(paths: Paths(root: root))
        let space = Space(name: "Work", slug: "work", colorHex: "#5E81F4")
        try store.save(space)
        try store.save(AppStateFile(spaceOrder: [space.id], selectedSpaceID: space.id))
        let state = TestAppState.make(root: root)

        let window = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: 900, height: windowHeight),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFront(nil)

        let controller = state.inbox.panelController
        controller.parentWindow = { window }
        controller.appIsActive = { false }
        return Fixture(root: root, state: state, space: space, window: window)
    }

    private func tearDown(_ f: Fixture) {
        f.center.closePanel()
        f.window.close()
        TestAppState.shutDown(f.state)
        try? FileManager.default.removeItem(at: f.root)
    }

    private func tab(_ spaceID: UUID) -> TabFacts {
        TabFacts(tabID: UUID(), spaceID: spaceID, foregroundProgram: "claude", isLookedAt: false)
    }

    private func status(_ state: ProgramState, _ kind: InboxWaitingReason? = nil, _ message: String) -> TerminalSignal {
        .status([StatusRecord(id: "", state: state, kind: kind, app: "claude-code", message: message)])
    }

    /// One entry of every kind (and both approval shapes, and a waiting entry without a message),
    /// built with Core's own methods.
    private func everyKind(_ spaceID: UUID, message: String = "Which database should the history use?",
                           block: String = "npm run deploy") -> Inbox {
        var inbox = Inbox()
        let now = Date()
        _ = inbox.apply(status(.blocked, .question, message), tab: tab(spaceID), agent: "Claude Code", now: now)
        _ = inbox.apply(.bell, tab: tab(spaceID), agent: "Hermes", now: now)
        _ = inbox.apply(status(.done, nil, message), tab: tab(spaceID), agent: "Codex", now: now.addingTimeInterval(-240))
        _ = inbox.hold(.question([InboxQuestion(question: message, header: "Database", options: ["SQLite", "Postgres"]),
                                  InboxQuestion(question: message, options: ["A", "B"], multiSelect: true)]),
                       tab: tab(spaceID), agent: "Claude Code", now: now)
        _ = inbox.hold(.permission(tool: "Bash", input: block), tab: tab(spaceID), agent: "Claude Code", now: now)
        _ = inbox.addApproval(InboxApproval(actor: "Claude Code", action: "click", detail: message, url: "https://example.com/",
                                            tabTitle: "Shop", text: block, siteHost: "example.com"),
                              spaceID: spaceID, tabID: UUID(), deadline: now.addingTimeInterval(95), now: now)
        _ = inbox.addApproval(InboxApproval(actor: "Claude Code", action: "open a page", detail: message),
                              spaceID: spaceID, tabID: nil, deadline: now.addingTimeInterval(95), now: now)
        return inbox
    }

    private func views(in view: NSView?) -> [NSView] {
        guard let view else { return [] }
        return [view] + view.subviews.flatMap { views(in: $0) }
    }

    private func escape(for window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                      windowNumber: window.windowNumber, context: nil, characters: "\u{1b}",
                                      charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
    }

    private func mouseDown(at point: NSPoint, in window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
                                        windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                        clickCount: 1, pressure: 1))
    }

    // MARK: Required

    @Test func selfOpenedPanelDoesNotTakeFocus() throws {
        let f = try makeFixture()
        defer { tearDown(f) }
        f.center.replaceInboxForTesting(everyKind(f.space.id))
        let field = NSTextField(frame: NSRect(x: 20, y: 20, width: 200, height: 24))
        f.window.contentView?.addSubview(field)
        f.window.makeFirstResponder(field)
        let responderBefore = f.window.firstResponder
        let windowWasKey = f.window.isKeyWindow
        let appKeyBefore = NSApp.keyWindow

        f.controller.show(relativeTo: nil, takingFocus: false)
        let panel = try #require(f.controller.panel)
        #expect(panel.isVisible)
        #expect(f.controller.isShown && f.center.isPanelShown)
        #expect(f.window.firstResponder === responderBefore)
        #expect(f.window.isKeyWindow == windowWasKey)
        #expect(NSApp.keyWindow === appKeyBefore)
        #expect(!panel.isKeyWindow)
        // What keeps it from ever becoming key while self-opened, even when clicked.
        #expect(!panel.canBecomeKey)
        #expect(panel.styleMask.contains(.nonactivatingPanel))
        #expect(panel.becomesKeyOnlyIfNeeded)
        #expect(!panel.hidesOnDeactivate)
        #expect(panel.parent === f.window)

        // Opened by the owner: it may become key, but never while the app is not active.
        f.controller.show(relativeTo: nil, takingFocus: true)
        #expect(panel.canBecomeKey)
        #expect(!panel.isKeyWindow)
        #expect(f.window.firstResponder === responderBefore)
    }

    @Test func noDefaultButtonInThePanel() async throws {
        let f = try makeFixture()
        defer { tearDown(f) }
        f.center.replaceInboxForTesting(everyKind(f.space.id))
        f.center.showPanel(takingFocus: true)
        let panel = try #require(f.controller.panel)
        panel.contentView?.layoutSubtreeIfNeeded()
        try await waitUntil("the panel to size itself") { f.controller.contentHeight > 100 }
        panel.contentView?.layoutSubtreeIfNeeded()

        #expect(panel.defaultButtonCell == nil)
        // SwiftUI's buttons on macOS are NSButtons (SwiftUIAppKitButton).
        let buttons = views(in: panel.contentView).compactMap { $0 as? NSButton }
        #expect(buttons.count >= 5)
        for button in buttons {
            #expect(button.keyEquivalent != "\r", "\(button.title) is a default button")
        }

        // SwiftUI handles `.keyboardShortcut(.defaultAction)` itself rather than through the
        // NSButton's key equivalent, so also press Return and Space at the panel and see that
        // nothing was answered or dismissed.
        let before = f.center.inbox.visible
        for (key, code) in [("\r", UInt16(36)), (" ", UInt16(49))] {
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                      windowNumber: panel.windowNumber, context: nil, characters: key,
                                                      charactersIgnoringModifiers: key, isARepeat: false, keyCode: code))
            #expect(!panel.performKeyEquivalent(with: event))
            panel.sendEvent(event)
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(f.center.inbox.visible == before)
        #expect(f.controller.isShown)
    }

    @Test func escClosesWithoutAnswering() throws {
        let f = try makeFixture()
        defer { tearDown(f) }
        f.center.replaceInboxForTesting(everyKind(f.space.id))
        let before = f.center.inbox.visible
        f.center.showPanel(takingFocus: true)
        let panel = try #require(f.controller.panel)
        #expect(f.controller.isShown)

        panel.sendEvent(try escape(for: panel))
        #expect(!f.controller.isShown)
        #expect(!f.center.isPanelShown)
        #expect(!panel.isVisible)
        #expect(f.center.inbox.visible == before)
    }

    // MARK: More

    /// Every kind of card, with the longest texts the inbox lets through, lays out at 330 pt in
    /// light and dark mode and draws.
    @Test func everyCardFitsTheWidth() throws {
        let f = try makeFixture()
        defer { tearDown(f) }
        let longMessage = String(repeating: "Lorem ipsum dolor sit amet, ", count: 30)
            .prefix(InboxText.messageLimit - 40) + String(repeating: "x", count: 40)
        let block = (0..<200).map { "line \($0): rm -rf build/output-\($0)" }.joined(separator: "\n")
        let longBlock = String(block.prefix(InboxText.inputLimit))
        #expect(longMessage.count == InboxText.messageLimit)
        #expect(longBlock.count == InboxText.inputLimit)
        f.center.replaceInboxForTesting(everyKind(f.space.id, message: String(longMessage), block: longBlock))
        #expect(f.center.inbox.visible.count == 7)

        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try #require(NSAppearance(named: name))
            let controller = NSHostingController(rootView: InboxListView(center: f.center, onAction: { _ in }))
            controller.view.appearance = appearance
            let size = controller.sizeThatFits(in: CGSize(width: InboxPanelController.width, height: 100_000))
            #expect(size.height.isFinite && size.height > 200, "\(name.rawValue): height \(size.height)")
            #expect(size.width <= InboxPanelController.width + 0.5, "\(name.rawValue): width \(size.width)")

            // Draw it once, as the panel would.
            let view = controller.view
            view.frame = NSRect(origin: .zero, size: CGSize(width: InboxPanelController.width, height: size.height))
            view.layoutSubtreeIfNeeded()
            let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: rep)
            #expect(rep.pixelsWide > 0)
        }
    }

    @Test func panelHeightIsCappedAndTheListScrolls() async throws {
        let f = try makeFixture(windowHeight: 500)
        defer { tearDown(f) }
        var inbox = Inbox()
        for i in 0..<40 {
            _ = inbox.apply(status(.blocked, .attention, "Agent \(i) waits for you"), tab: tab(f.space.id),
                            agent: "Claude Code", now: Date())
        }
        f.center.replaceInboxForTesting(inbox)
        f.center.showPanel(takingFocus: false)
        let panel = try #require(f.controller.panel)
        let cap = f.window.frame.height * 0.7

        try await waitUntil("the panel to reach its height") { abs(panel.frame.height - cap) < 1 }
        #expect(f.controller.contentHeight > cap * 2)
        #expect(panel.frame.width == InboxPanelController.width)

        // The list is in a scroll view whose content is taller than what it shows.
        panel.contentView?.layoutSubtreeIfNeeded()
        let scrollViews = views(in: panel.contentView).compactMap { $0 as? NSScrollView }
        let scroll = try #require(scrollViews.max { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) })
        #expect((scroll.documentView?.frame.height ?? 0) > scroll.contentView.bounds.height + 100)

        // A short list makes a short panel.
        var few = Inbox()
        _ = few.apply(.bell, tab: tab(f.space.id), agent: "Hermes", now: Date())
        f.center.replaceInboxForTesting(few)
        try await waitUntil("the panel to shrink") { panel.frame.height < cap - 50 }
        #expect(panel.frame.height > 40)
    }

    /// The click-outside monitor's handler, called directly with events that are made but never
    /// posted. Clicks in the panel or on the rail button leave it open; any other click in the
    /// window closes it and goes on to where it was aimed.
    @Test func clickOutsideClosesThePanel() throws {
        let f = try makeFixture()
        defer { tearDown(f) }
        f.center.replaceInboxForTesting(everyKind(f.space.id))
        let anchor = NSView(frame: NSRect(x: 10, y: 500, width: 28, height: 28))
        f.window.contentView?.addSubview(anchor)
        f.controller.show(relativeTo: anchor, takingFocus: false)
        let panel = try #require(f.controller.panel)

        // Beside the button: top-left 6 pt right of it, tops level.
        let anchorOnScreen = f.window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        #expect(abs(panel.frame.minX - (anchorOnScreen.maxX + 6)) < 0.5)
        #expect(abs(panel.frame.maxY - anchorOnScreen.maxY) < 0.5)

        let inPanel = try mouseDown(at: NSPoint(x: 20, y: 20), in: panel)
        #expect(f.controller.handleMouseDown(inPanel) === inPanel)
        #expect(f.controller.isShown)

        let onButton = try mouseDown(at: NSPoint(x: 20, y: 510), in: f.window)
        #expect(f.controller.handleMouseDown(onButton) === onButton)
        #expect(f.controller.isShown)

        let elsewhere = try mouseDown(at: NSPoint(x: 600, y: 100), in: f.window)
        #expect(f.controller.handleMouseDown(elsewhere) === elsewhere)
        #expect(!f.controller.isShown)
        #expect(!f.center.isPanelShown)
        #expect(!panel.isVisible)
    }

    @Test func goToClosesThePanel() throws {
        let f = try makeFixture()
        defer { tearDown(f) }
        f.center.replaceInboxForTesting(everyKind(f.space.id))
        f.center.showPanel(takingFocus: true)
        let panel = try #require(f.controller.panel)
        let entry = try #require(f.center.inbox.visible.first { $0.kind == .done })
        f.center.goTo(entry)
        #expect(!f.controller.isShown)
        #expect(!f.center.isPanelShown)
        #expect(!panel.isVisible)
        #expect(panel.parent == nil)
    }

    /// The panel's SwiftUI content must not keep the inbox alive (inbox → panel → content → inbox).
    @Test func panelDoesNotKeepTheInboxAlive() throws {
        MainRunLoopGuard.start
        let window = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: 900, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        defer { window.close() }
        weak var released: InboxCenter?
        autoreleasepool {
            let center = InboxCenter()
            center.panelController.parentWindow = { window }
            center.panelController.appIsActive = { false }
            center.showPanel(takingFocus: false)
            center.panelController.panel?.contentView?.layoutSubtreeIfNeeded()
            center.closePanel()
            released = center
        }
        #expect(released == nil)
    }

    /// The terminal's folder comes from the shell: cleaned like any other text on a card.
    @Test func folderIsCleaned() {
        let home = NSHomeDirectory()
        #expect(InboxPlace.folderText(home + "/Developer/site") == "~/Developer/site")
        #expect(InboxPlace.folderText("/tmp/evil\u{202E}txt.\u{0007}sh") == "/tmp/eviltxt.sh")
        #expect(InboxPlace.folderText("/" + String(repeating: "a", count: 200)).count == 80)
    }

    @Test func countBadgeIsHiddenAtZero() {
        MainRunLoopGuard.start
        #expect(NSHostingView(rootView: InboxCountBadge(count: 0)).fittingSize == .zero)
        let three = NSHostingView(rootView: InboxCountBadge(count: 3)).fittingSize
        #expect(three.width > 0 && three.height > 0)
    }

    @Test func chipTexts() {
        let now = Date(timeIntervalSince1970: 10_000)
        #expect(InboxChipText.done(since: now.addingTimeInterval(-30), now: now) == "done")
        #expect(InboxChipText.done(since: now.addingTimeInterval(-245), now: now) == "done · 4 min")
        #expect(InboxChipText.done(since: now.addingTimeInterval(-7300), now: now) == "done · 2 h")
        #expect(InboxChipText.timeLeft(until: now.addingTimeInterval(105), now: now) == "1:45 left")
        #expect(InboxChipText.timeLeft(until: now.addingTimeInterval(-3), now: now) == "0:00 left")
    }

    @Test func paletteOffersShowInbox() throws {
        let f = try makeFixture()
        defer { tearDown(f) }
        let items = PaletteResults.items(for: "", mode: .newTab, state: f.state)
        let item = try #require(items.first { $0.id == "cmd-show-inbox" })
        #expect(item.title == "Show Inbox")
    }
}
}
