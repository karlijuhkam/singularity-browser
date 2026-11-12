import AppKit
import Foundation
import SwiftUI
import Testing
import WebKit
@testable import Singularity
import SingularityCore

extension AppTests {
/// Browser approvals as inbox entries (they replaced the approval sheet): every answer, the
/// timeout, Show Tab, "Allow on <site>" releasing other requests, and every way an entry can go
/// without an answer. Unanswered is always denied, and each waiting `check` gets exactly one answer.
///
/// No test here makes a window key or activates the app; the panel's controller is told the app
/// is never active.
@MainActor
@Suite(.serialized) struct ApprovalInboxTests {
    /// An `AgentApprovals` wired to its own `InboxCenter`, as `AppState` wires them.
    @MainActor final class Rig {
        let approvals = AgentApprovals()
        let center: InboxCenter
        var arrivals: [InboxEntry] = []
        var attention = 0
        var active: Bool
        /// Added to the real time the inbox sees, so a test can step past the answer lockout.
        var skew: TimeInterval = 0

        init(center: InboxCenter = InboxCenter(), active: Bool = false) {
            self.center = center
            self.active = active
            center.now = { [unowned self] in Date().addingTimeInterval(self.skew) }
            center.appIsActive = { [unowned self] in self.active }
            center.onArrival = { [unowned self] in self.arrivals.append($0) }
            center.onChange = {}
            center.requestAttention = { [unowned self] in self.attention += 1 }
            approvals.presenter = { [center] in await center.requestApproval($0) }
        }

        /// As if more than the lockout had passed since the cards last moved.
        func passTheLockout() {
            skew += InboxCenter.answerLockout + 0.1
        }

        var waiting: [InboxEntry] {
            center.inbox.visible.filter { if case .approval = $0.kind { true } else { false } }
        }

        func check(_ context: AgentActionContext, _ space: Space, _ request: AgentApprovals.Request)
            -> Task<AgentApprovals.Outcome, Never> {
            Task { @MainActor in await approvals.check(context, space: space, request: request) }
        }

        /// Waits until `count` approvals are in the inbox and returns the newest.
        @discardableResult
        func waitForEntry(count: Int = 1) async throws -> InboxEntry {
            try await waitUntil("\(count) approval entries") { waiting.count >= count }
            return try #require(waiting.max { $0.arrived < $1.arrived })
        }
    }

    @MainActor final class Flag { var value = false }

    private func askingSpace() -> Space {
        var space = Space(name: "Work", slug: "work", colorHex: "#5E81F4")
        space.agentPolicy = .ask
        return space
    }

    private func clickRequest(tabID: UUID? = nil, showTab: (@MainActor () -> Void)? = nil) -> AgentApprovals.Request {
        var request = AgentApprovals.Request(actor: "Claude Code", action: "click", detail: "[2] button \"Buy\"",
                                             url: "https://example.com/", spaceName: "Work", tabTitle: "Shop", text: nil)
        request.tabID = tabID
        request.showTab = showTab
        return request
    }

    private let click = AgentActionContext(kind: .click, pageOrigin: "https://example.com")

    /// A `PendingApproval` straight to the inbox, with a timeout shorter than `check` allows.
    private func pending(_ space: Space, timeout: Duration, tabID: UUID? = nil,
                         passesNow: @escaping @MainActor () -> Bool = { false }) -> AgentApprovals.PendingApproval {
        AgentApprovals.PendingApproval(request: clickRequest(tabID: tabID), spaceID: space.id,
                                       siteOrigin: "https://example.com", timeout: timeout, passesNow: passesNow)
    }

    // MARK: Answers (ported from the approval sheet's tests)

    @Test func allowApproves() async throws {
        MainRunLoopGuard.start
        let rig = Rig()
        let answer = rig.check(click, askingSpace(), clickRequest())
        let entry = try await rig.waitForEntry()
        rig.center.decideApproval(entry.id, .approved)
        let outcome = await answer.value
        #expect(outcome.logValue == "approved")
        #expect(outcome.isAllowed)
        #expect(rig.waiting.isEmpty)
    }

    @Test func denyDenies() async throws {
        MainRunLoopGuard.start
        let rig = Rig()
        let answer = rig.check(click, askingSpace(), clickRequest())
        let entry = try await rig.waitForEntry()
        rig.center.decideApproval(entry.id, .denied)
        let outcome = await answer.value
        #expect(outcome.logValue == "denied")
        #expect(!outcome.isAllowed)
        #expect(outcome.refusal == "The user declined this action.")
        #expect(rig.waiting.isEmpty)
    }

    @Test func allowOnSiteIsRemembered() async throws {
        MainRunLoopGuard.start
        let rig = Rig()
        let space = askingSpace()
        let answer = rig.check(click, space, clickRequest())
        let entry = try await rig.waitForEntry()
        guard case .approval(let approval) = entry.kind else { Issue.record("not an approval"); return }
        #expect(approval.siteHost == "example.com")
        rig.center.decideApproval(entry.id, .approvedSite)
        #expect(await answer.value.logValue == "approved_site")

        // The same site again: let through without an entry.
        let again = await rig.approvals.check(click, space: space, request: clickRequest())
        #expect(again.logValue == "auto")
        #expect(rig.waiting.isEmpty)
    }

    @Test func timeoutDenies() async throws {
        MainRunLoopGuard.start
        let rig = Rig()
        rig.approvals.timeoutSeconds = { 5 }
        let started = ContinuousClock.now
        let answer = rig.check(click, askingSpace(), clickRequest())
        let entry = try await rig.waitForEntry()
        let deadline = try #require(entry.deadline)
        #expect(abs(deadline.timeIntervalSince(entry.arrived) - 5) < 0.5)
        let outcome = await answer.value
        #expect(ContinuousClock.now - started >= .seconds(4.9))
        #expect(outcome.logValue == "timeout")
        #expect(!outcome.isAllowed)
        #expect(rig.waiting.isEmpty)
    }

    @Test func showTabRestartsTheClock() async throws {
        MainRunLoopGuard.start
        let rig = Rig()
        rig.approvals.timeoutSeconds = { 5 }
        var shown = 0
        let answer = rig.check(click, askingSpace(), clickRequest(tabID: UUID(), showTab: { shown += 1 }))
        let entry = try await rig.waitForEntry()
        let firstDeadline = try #require(entry.deadline)

        try await Task.sleep(for: .seconds(3))
        rig.center.showApprovalTab(entry.id)
        #expect(shown == 1)
        let moved = try #require(rig.waiting.first?.deadline)
        #expect(moved.timeIntervalSince(firstDeadline) > 2.5)

        // Past the first deadline: still waiting (Show Tab does not answer, the clock restarted).
        try await Task.sleep(for: .seconds(3))
        #expect(rig.waiting.map(\.id) == [entry.id])
        rig.center.decideApproval(entry.id, .denied)
        #expect(await answer.value.logValue == "denied")
        #expect(shown == 1)
    }

    @Test func twoRequestsWaitTogether() async throws {
        MainRunLoopGuard.start
        let rig = Rig()
        let space = askingSpace()
        let first = rig.check(click, space, clickRequest())
        let firstEntry = try await rig.waitForEntry()
        let second = rig.check(AgentActionContext(kind: .click, pageOrigin: "https://other.example"), space, clickRequest())
        let secondEntry = try await rig.waitForEntry(count: 2)
        #expect(rig.waiting.count == 2)

        rig.center.decideApproval(firstEntry.id, .approved)
        #expect(await first.value.logValue == "approved")
        #expect(rig.waiting.map(\.id) == [secondEntry.id])

        rig.center.decideApproval(secondEntry.id, .denied)
        #expect(await second.value.logValue == "denied")
        #expect(rig.waiting.isEmpty)
    }

    @Test func allowOnSiteReleasesTheOtherRequestForThatSite() async throws {
        MainRunLoopGuard.start
        let rig = Rig()
        let space = askingSpace()
        let first = rig.check(click, space, clickRequest())
        let firstEntry = try await rig.waitForEntry()
        let second = rig.check(click, space, clickRequest())
        try await rig.waitForEntry(count: 2)

        rig.center.decideApproval(firstEntry.id, .approvedSite)
        #expect(await first.value.logValue == "approved_site")
        #expect(await second.value.logValue == "auto")
        #expect(rig.waiting.isEmpty)
    }

    @Test func alwaysAskIsNotReleased() async throws {
        MainRunLoopGuard.start
        let rig = Rig()
        let space = askingSpace()
        let first = rig.check(click, space, clickRequest())
        let firstEntry = try await rig.waitForEntry()
        // A click that submits a form on the same site: the rules always ask for that.
        let submit = AgentActionContext(kind: .click, pageOrigin: "https://example.com", isFormSubmission: true)
        let second = rig.check(submit, space, clickRequest())
        let secondEntry = try await rig.waitForEntry(count: 2)
        guard case .approval(let approval) = secondEntry.kind else { Issue.record("not an approval"); return }
        #expect(approval.siteHost == nil, "no \"Allow on\" for a form submission")

        rig.center.decideApproval(firstEntry.id, .approvedSite)
        #expect(await first.value.logValue == "approved_site")
        try await Task.sleep(for: .milliseconds(300))
        #expect(rig.waiting.map(\.id) == [secondEntry.id], "a form submission must still ask")

        rig.center.decideApproval(secondEntry.id, .denied)
        #expect(await second.value.logValue == "denied")
    }

    @Test func noPresenterDenies() async {
        let approvals = AgentApprovals()
        #expect(approvals.presenter == nil)
        let outcome = await approvals.check(click, space: askingSpace(), request: clickRequest())
        #expect(outcome.logValue == "denied")
        #expect(!outcome.isAllowed)
    }

    /// "Allow on <site>" without a site to allow is no answer at all: the request keeps waiting.
    @Test func allowOnSiteWithoutASiteIsIgnored() async throws {
        MainRunLoopGuard.start
        let rig = Rig()
        let prompt = AgentActionContext(kind: .artifactPrompt, pageOrigin: "http://127.0.0.1:5000")
        let answer = rig.check(prompt, askingSpace(), clickRequest())
        let entry = try await rig.waitForEntry()
        rig.center.decideApproval(entry.id, .approvedSite)
        rig.center.decideApproval(entry.id, .auto)
        rig.center.decideApproval(entry.id, .timedOut)
        try await Task.sleep(for: .milliseconds(100))
        #expect(rig.waiting.map(\.id) == [entry.id])
        rig.center.decideApproval(entry.id, .denied)
        #expect(await answer.value.logValue == "denied")
    }

    // MARK: Arrival

    @Test func selfOpenedForApprovalDoesNotTakeFocus() async throws {
        MainRunLoopGuard.start
        let window = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: 900, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        let field = NSTextField(frame: NSRect(x: 20, y: 20, width: 200, height: 24))
        window.contentView?.addSubview(field)
        window.makeFirstResponder(field)
        let responderBefore = window.firstResponder
        let appKeyBefore = NSApp.keyWindow

        let rig = Rig(active: true)
        rig.center.panelController.parentWindow = { window }
        rig.center.panelController.appIsActive = { false }
        defer {
            rig.center.closePanel()
            window.close()
        }

        // Singularity active: the panel opens by itself, without the keyboard, and no notification.
        let first = rig.check(click, askingSpace(), clickRequest())
        let firstEntry = try await rig.waitForEntry()
        let panel = try #require(rig.center.panelController.panel)
        #expect(rig.center.isPanelShown && panel.isVisible)
        #expect(!panel.canBecomeKey)
        #expect(!panel.isKeyWindow)
        #expect(window.firstResponder === responderBefore)
        #expect(NSApp.keyWindow === appKeyBefore)
        #expect(rig.arrivals.isEmpty)
        #expect(rig.attention == 0)
        rig.center.decideApproval(firstEntry.id, .denied)
        _ = await first.value

        // Not active: notification and Dock bounce, and the panel is not forced open.
        rig.center.closePanel()
        rig.active = false
        let second = rig.check(click, askingSpace(), clickRequest())
        let secondEntry = try await rig.waitForEntry()
        #expect(!rig.center.isPanelShown)
        #expect(rig.arrivals.map(\.id) == [secondEntry.id])
        #expect(rig.attention == 1)
        rig.center.decideApproval(secondEntry.id, .denied)
        _ = await second.value
    }

    // MARK: The card

    private func buttons(in view: NSView?) -> [NSButton] {
        guard let view else { return [] }
        return view.subviews.flatMap { buttons(in: $0) } + ((view as? NSButton).map { [$0] } ?? [])
    }

    private func titles(_ choices: [InboxApprovalButtons.Choice]) -> [String] {
        choices.map(\.title)
    }

    /// The approval card offers Allow, Allow on <site>, Deny and Show Tab, and each does what it
    /// says. On the real panel nothing is a default button: Return and Space answer nothing.
    ///
    /// SwiftUI draws these buttons itself (no titled NSButtons, and no accessibility nodes without
    /// an assistive client), so the titles are read from `InboxApprovalButtons.choices`, the list
    /// the card's view shows.
    @Test func cardHasTheButtonsAndNoDefaultButton() async throws {
        MainRunLoopGuard.start
        let window = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: 900, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        let rig = Rig()
        rig.center.panelController.parentWindow = { window }
        rig.center.panelController.appIsActive = { false }
        defer {
            rig.center.closePanel()
            window.close()
        }

        var shown = 0
        var request = clickRequest(tabID: UUID(), showTab: { shown += 1 })
        request.text = "hello\u{202E}evil\nsecond line"
        let answer = rig.check(click, askingSpace(), request)
        let entry = try await rig.waitForEntry()
        let choices = InboxApprovalButtons.choices(for: entry)
        #expect(titles(choices.answers) == ["Allow", "Allow on example.com", "Deny"])
        #expect(choices.showTab?.title == "Show Tab")
        // The text a page sent is shown cleaned (direction override gone, line break kept).
        guard case .approval(let approval) = entry.kind else { Issue.record("not an approval"); return }
        #expect(InboxApprovalText(approval).text == "helloevil\nsecond line")
        #expect(InboxApprovalText(approval).headline == "Claude Code wants to click")

        rig.center.showPanel(takingFocus: true)
        let panel = try #require(rig.center.panelController.panel)
        try await waitUntil("the panel to size itself") { rig.center.panelController.contentHeight > 60 }
        panel.contentView?.layoutSubtreeIfNeeded()
        #expect(panel.defaultButtonCell == nil)
        for button in buttons(in: panel.contentView) {
            #expect(button.keyEquivalent != "\r", "\(button.title) is a default button")
        }
        for (key, code) in [("\r", UInt16(36)), (" ", UInt16(49))] {
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                      windowNumber: panel.windowNumber, context: nil, characters: key,
                                                      charactersIgnoringModifiers: key, isARepeat: false, keyCode: code))
            #expect(!panel.performKeyEquivalent(with: event))
            panel.sendEvent(event)
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(rig.waiting.map(\.id) == [entry.id])

        // Show Tab: shows the tab, answers nothing, the panel stays open.
        rig.center.perform(try #require(choices.showTab).action)
        #expect(shown == 1)
        #expect(rig.waiting.map(\.id) == [entry.id])
        #expect(rig.center.isPanelShown)

        // Allow answers (once the panel has been up for a moment).
        rig.passTheLockout()
        rig.center.perform(choices.answers[0].action)
        #expect(await answer.value.logValue == "approved")
        #expect(rig.waiting.isEmpty)
    }

    @Test func cardButtonsAnswerAsTheySay() async throws {
        MainRunLoopGuard.start
        let rig = Rig()
        let space = askingSpace()
        for (index, expected) in [(1, "approved_site"), (2, "denied")] {
            let answer = rig.check(AgentActionContext(kind: .click, pageOrigin: "https://site\(index).example"), space, clickRequest())
            let entry = try await rig.waitForEntry()
            let choices = InboxApprovalButtons.choices(for: entry)
            #expect(choices.answers.count == 3)
            rig.passTheLockout()
            rig.center.perform(choices.answers[index].action)
            #expect(await answer.value.logValue == expected)
        }
    }

    /// No site to allow and no tab (an artifact prompt): neither "Allow on" nor "Show Tab".
    @Test func cardWithoutSiteOrTab() async throws {
        MainRunLoopGuard.start
        let rig = Rig()
        let request = AgentApprovals.Request(actor: "An artifact page", action: "send text to a terminal",
                                             detail: "It will be pasted.", url: nil, spaceName: "Work",
                                             tabTitle: nil, text: "some text")
        let answer = rig.check(AgentActionContext(kind: .artifactPrompt, pageOrigin: "http://127.0.0.1:5000"),
                               askingSpace(), request)
        let entry = try await rig.waitForEntry()
        #expect(entry.tabID == nil)
        guard case .approval(let approval) = entry.kind else { Issue.record("not an approval"); return }
        #expect(approval.text == "some text")
        let choices = InboxApprovalButtons.choices(for: entry)
        #expect(titles(choices.answers) == ["Allow", "Deny"])
        #expect(choices.showTab == nil)
        // Show Tab without a tab does nothing, and does not restart the clock.
        let deadline = entry.deadline
        rig.center.showApprovalTab(entry.id)
        #expect(rig.waiting.first?.deadline == deadline)

        rig.passTheLockout()
        rig.center.perform(choices.answers[1].action)
        #expect(await answer.value.logValue == "denied")
    }

    // MARK: Clicks while the cards move (review item 1)

    /// An answer click right after the cards changed is ignored (nothing answered, no deny); after
    /// the lockout it counts. A double-click on Deny cannot land on the next card's Allow.
    /// `decideApproval` itself (not a click) is never held back.
    @Test func answersWaitAfterTheCardsMove() async throws {
        MainRunLoopGuard.start
        let rig = Rig()
        let space = askingSpace()
        let first = rig.check(click, space, clickRequest())
        let a = try await rig.waitForEntry()
        // Arrived just now: a click is ignored.
        rig.center.perform(.decideApproval(a.id, .denied))
        try await Task.sleep(for: .milliseconds(50))
        #expect(rig.waiting.map(\.id) == [a.id])

        let second = rig.check(AgentActionContext(kind: .click, pageOrigin: "https://other.example"), space, clickRequest())
        let b = try await rig.waitForEntry(count: 2)
        rig.passTheLockout()
        // Deny on the first card counts; the second click of a double-click, now on the next
        // card's Allow, does not.
        rig.center.perform(.decideApproval(a.id, .denied))
        rig.center.perform(.decideApproval(b.id, .approved))
        #expect(await first.value.logValue == "denied")
        try await Task.sleep(for: .milliseconds(50))
        #expect(rig.waiting.map(\.id) == [b.id])
        #expect(rig.center.answersUnlockAt > rig.center.now())

        // Not a click: answered at once.
        rig.center.decideApproval(b.id, .denied)
        #expect(await second.value.logValue == "denied")
    }

    /// The panel appearing (by itself or opened) holds answer clicks back for a moment too.
    @Test func panelAppearingHoldsAnswersBack() async throws {
        MainRunLoopGuard.start
        let window = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: 900, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        let rig = Rig()
        rig.center.panelController.parentWindow = { window }
        rig.center.panelController.appIsActive = { false }
        defer {
            rig.center.closePanel()
            window.close()
        }
        let answer = rig.check(click, askingSpace(), clickRequest())
        let entry = try await rig.waitForEntry()
        #expect(!rig.center.isPanelShown)
        rig.passTheLockout()

        rig.center.showPanel(takingFocus: true)
        rig.center.perform(.decideApproval(entry.id, .approved))
        try await Task.sleep(for: .milliseconds(50))
        #expect(rig.waiting.map(\.id) == [entry.id])

        // Showing an already open panel again does not move the lock.
        rig.passTheLockout()
        rig.center.showPanel(takingFocus: false)
        rig.center.perform(.decideApproval(entry.id, .approved))
        #expect(await answer.value.logValue == "approved")
    }

    // MARK: Limits and the defensive checks (review items 2, 3, 5, 7)

    @Test func tooManyWaitingAreDenied() async throws {
        MainRunLoopGuard.start
        let rig = Rig()
        let space = askingSpace()
        let other = askingSpace()
        let limit = InboxCenter.maxWaitingApprovalsPerSpace
        #expect(limit == 5)
        var answers: [Task<AgentApprovals.Outcome, Never>] = []
        for _ in 0..<limit {
            answers.append(Task { @MainActor in await rig.center.requestApproval(pending(space, timeout: .seconds(30))) })
        }
        try await rig.waitForEntry(count: limit)
        // One more in the same Space: "no" at once, no entry, no notification.
        let arrivalsBefore = rig.arrivals.count
        let extra = await rig.center.requestApproval(pending(space, timeout: .seconds(30)))
        #expect(extra.logValue == "denied")
        #expect(rig.waiting.count == limit)
        #expect(rig.arrivals.count == arrivalsBefore)
        // Another Space is not affected.
        let otherAnswer = Task { @MainActor in await rig.center.requestApproval(pending(other, timeout: .seconds(30))) }
        try await rig.waitForEntry(count: limit + 1)
        // Through `check` too (the artifact prompt's path): denied, logged as "denied".
        let prompt = await rig.approvals.check(AgentActionContext(kind: .artifactPrompt, pageOrigin: "http://127.0.0.1:5000"),
                                               space: space, request: clickRequest())
        #expect(prompt.logValue == "denied")

        rig.center.denyAllApprovals()
        for answer in answers { #expect(await answer.value.logValue == "denied") }
        _ = await otherAnswer.value
        // Room again once they are answered.
        let again = rig.check(click, space, clickRequest())
        let entry = try await rig.waitForEntry()
        rig.center.decideApproval(entry.id, .approved)
        #expect(await again.value.logValue == "approved")
    }

    /// `ask` does not trust the presenter: anything but a real answer ends as "no".
    @Test func askTreatsOddAnswersAsNo() async {
        let space = askingSpace()
        func outcome(_ fake: AgentApprovals.Outcome, _ context: AgentActionContext) async -> String {
            let approvals = AgentApprovals()
            approvals.presenter = { _ in fake }
            return await approvals.check(context, space: space, request: clickRequest()).logValue
        }
        let prompt = AgentActionContext(kind: .artifactPrompt, pageOrigin: "http://127.0.0.1:5000")
        // `.auto` while the rules still ask.
        #expect(await outcome(.auto, click) == "denied")
        // "Allow on <site>" for a request without a site.
        #expect(await outcome(.approvedSite, prompt) == "denied")
        #expect(await outcome(.refused("x"), click) == "denied")
        // The real answers pass through.
        #expect(await outcome(.approved, click) == "approved")
        #expect(await outcome(.approvedSite, click) == "approved_site")
        #expect(await outcome(.denied, click) == "denied")
        #expect(await outcome(.timedOut, click) == "timeout")
    }

    @MainActor final class SpaceBox {
        var space: Space?
        init(_ space: Space) { self.space = space }
    }

    /// The Space was made read-only (or deleted) while the request waited: a later Allow, or
    /// Allow on <site>, no longer lets the action through, and the site is not remembered.
    @Test func answerAfterAPolicyChangeIsNo() async throws {
        MainRunLoopGuard.start
        let rig = Rig()
        let box = SpaceBox(askingSpace())
        let space = try #require(box.space)
        rig.approvals.currentSpace = { [box] id in box.space?.id == id ? box.space : nil }

        for answer in [AgentApprovals.Outcome.approved, .approvedSite] {
            box.space?.agentPolicy = .ask
            let request = rig.check(click, space, clickRequest())
            let entry = try await rig.waitForEntry()
            box.space?.agentPolicy = .readOnly
            rig.center.decideApproval(entry.id, answer)
            #expect(await request.value.logValue == "denied")
        }
        // The site was not remembered: with "ask" again, it asks again.
        box.space?.agentPolicy = .ask
        let asksAgain = rig.check(click, space, clickRequest())
        let entry = try await rig.waitForEntry()
        // Deleted while waiting.
        box.space = nil
        rig.center.decideApproval(entry.id, .approved)
        #expect(await asksAgain.value.logValue == "denied")
    }

    /// "Go to terminal"'s path for an approval is Show Tab: it shows the tab, restarts the clock
    /// and leaves the request waiting.
    @Test func goToAnApprovalIsShowTab() async throws {
        MainRunLoopGuard.start
        let rig = Rig()
        var shown = 0
        let answer = rig.check(click, askingSpace(), clickRequest(tabID: UUID(), showTab: { shown += 1 }))
        let entry = try await rig.waitForEntry()
        let before = try #require(entry.deadline)
        rig.skew += 3
        rig.center.goTo(entry)
        #expect(shown == 1)
        let after = try #require(rig.waiting.first?.deadline)
        #expect(after.timeIntervalSince(before) > 2.5)
        #expect(rig.waiting.map(\.id) == [entry.id])
        rig.center.decideApproval(entry.id, .denied)
        #expect(await answer.value.logValue == "denied")
    }

    /// A long site name still fits the panel's width.
    @Test func longSiteNameFits() throws {
        MainRunLoopGuard.start
        let center = InboxCenter()
        var inbox = Inbox()
        let host = String(repeating: "very-long-subdomain.", count: 6) + "example.com"
        _ = inbox.addApproval(InboxApproval(actor: "Claude Code", action: "click", detail: "[2] button",
                                            url: "https://\(host)/", tabTitle: "Shop", text: "x",
                                            siteHost: host),
                              spaceID: UUID(), tabID: UUID(), deadline: Date().addingTimeInterval(60), now: Date())
        center.replaceInboxForTesting(inbox)
        let controller = NSHostingController(rootView: InboxListView(center: center, onAction: { _ in }))
        let size = controller.sizeThatFits(in: CGSize(width: InboxPanelController.width, height: 100_000))
        #expect(size.width <= InboxPanelController.width + 0.5, "width \(size.width)")
    }

    // MARK: Leaving without an answer

    @Test func dismissalIsNotApproval() async throws {
        MainRunLoopGuard.start
        let window = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: 900, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        let rig = Rig(active: true)
        rig.center.panelController.parentWindow = { window }
        rig.center.panelController.appIsActive = { false }
        defer {
            rig.center.closePanel()
            window.close()
        }
        let space = askingSpace()

        let answer = Task { @MainActor in await rig.center.requestApproval(pending(space, timeout: .seconds(1))) }
        let entry = try await rig.waitForEntry()
        #expect(rig.center.isPanelShown)
        // Esc, then the panel closed in code (as a click outside does).
        let panel = try #require(rig.center.panelController.panel)
        let escape = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                   windowNumber: panel.windowNumber, context: nil, characters: "\u{1b}",
                                                   charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        panel.sendEvent(escape)
        #expect(!rig.center.isPanelShown)
        rig.center.closePanel()
        #expect(rig.waiting.map(\.id) == [entry.id])

        let outcome = await answer.value
        #expect(outcome.logValue == "timeout")
        #expect(rig.waiting.isEmpty)
    }

    @Test func spaceDeletedDenies() async throws {
        MainRunLoopGuard.start
        let rig = Rig()
        let space = askingSpace()
        let other = askingSpace()
        let answer = Task { @MainActor in await rig.center.requestApproval(pending(space, timeout: .seconds(30))) }
        let otherAnswer = Task { @MainActor in await rig.center.requestApproval(pending(other, timeout: .seconds(30))) }
        try await rig.waitForEntry(count: 2)
        rig.center.spaceDeleted(space.id)
        #expect(await answer.value.logValue == "denied")
        #expect(rig.waiting.map(\.spaceID) == [other.id])
        rig.center.decideApproval(try #require(rig.waiting.first).id, .denied)
        _ = await otherAnswer.value
    }

    @Test func appQuitDenies() async throws {
        MainRunLoopGuard.start
        let rig = Rig()
        let space = askingSpace()
        let first = Task { @MainActor in await rig.center.requestApproval(pending(space, timeout: .seconds(30))) }
        let second = Task { @MainActor in await rig.center.requestApproval(pending(space, timeout: .seconds(30), tabID: UUID())) }
        try await rig.waitForEntry(count: 2)
        rig.center.denyAllApprovals()
        #expect(await first.value.logValue == "denied")
        #expect(await second.value.logValue == "denied")
        #expect(rig.waiting.isEmpty)
    }

    /// Dismissing an approval entry (only possible in code) is a "no".
    @Test func dismissingAnApprovalDenies() async throws {
        MainRunLoopGuard.start
        let rig = Rig()
        let answer = rig.check(click, askingSpace(), clickRequest())
        let entry = try await rig.waitForEntry()
        rig.center.dismiss(entry.id)
        #expect(await answer.value.logValue == "denied")
    }

    /// Every way an approval can end, tried again after it ended (and in the other order): the
    /// waiting `check` gets the first answer only. A second resume of its continuation would trap.
    @Test func eachRequestIsAnsweredOnce() async throws {
        MainRunLoopGuard.start
        let rig = Rig()
        let space = askingSpace()
        let tabID = UUID()
        func tryEverything(_ id: UUID) {
            rig.center.decideApproval(id, .approved)
            rig.center.decideApproval(id, .approvedSite)
            rig.center.decideApproval(id, .denied)
            rig.center.showApprovalTab(id)
            rig.center.dismiss(id)
            rig.center.tabClosed(tabID)
            rig.center.spaceDeleted(space.id)
            rig.center.denyAllApprovals()
        }

        // Answer, then the timeout passes.
        let answered = Task { @MainActor in await rig.center.requestApproval(pending(space, timeout: .milliseconds(300), tabID: tabID)) }
        let a = try await rig.waitForEntry()
        rig.center.decideApproval(a.id, .denied)
        try await Task.sleep(for: .milliseconds(500))
        tryEverything(a.id)
        #expect(await answered.value.logValue == "denied")

        // Timeout, then answers.
        let timedOut = Task { @MainActor in await rig.center.requestApproval(pending(space, timeout: .milliseconds(300), tabID: tabID)) }
        let b = try await rig.waitForEntry()
        #expect(await timedOut.value.logValue == "timeout")
        tryEverything(b.id)

        // Released by "Allow on site" elsewhere, then the timeout passes and answers come.
        let passes = Flag()
        let released = Task { @MainActor in
            await rig.center.requestApproval(pending(space, timeout: .milliseconds(400), tabID: tabID, passesNow: { passes.value }))
        }
        let c = try await rig.waitForEntry()
        let site = Task { @MainActor in await rig.center.requestApproval(pending(space, timeout: .seconds(30))) }
        let d = try await rig.waitForEntry(count: 2)
        passes.value = true
        rig.center.decideApproval(d.id, .approvedSite)
        #expect(await site.value.logValue == "approved_site")
        #expect(await released.value.logValue == "auto")
        try await Task.sleep(for: .milliseconds(600))
        tryEverything(c.id)
        tryEverything(d.id)

        // Tab closed, then everything else.
        let closed = Task { @MainActor in await rig.center.requestApproval(pending(space, timeout: .milliseconds(300), tabID: tabID)) }
        let e = try await rig.waitForEntry()
        rig.center.tabClosed(tabID)
        #expect(await closed.value.logValue == "denied")
        try await Task.sleep(for: .milliseconds(500))
        tryEverything(e.id)
        #expect(rig.waiting.isEmpty)
    }

    /// `.auto` only while the rules let it through at that moment: a request whose `passesNow`
    /// turned false again is not released.
    @Test func autoOnlyWhenTheRulesPassNow() async throws {
        MainRunLoopGuard.start
        let rig = Rig()
        let space = askingSpace()
        let other = Task { @MainActor in
            await rig.center.requestApproval(pending(space, timeout: .seconds(30), passesNow: { false }))
        }
        let otherEntry = try await rig.waitForEntry()
        let site = Task { @MainActor in await rig.center.requestApproval(pending(space, timeout: .seconds(30))) }
        let siteEntry = try await rig.waitForEntry(count: 2)
        rig.center.decideApproval(siteEntry.id, .approvedSite)
        _ = await site.value
        try await Task.sleep(for: .milliseconds(200))
        #expect(rig.waiting.map(\.id) == [otherEntry.id])
        rig.center.decideApproval(otherEntry.id, .denied)
        #expect(await other.value.logValue == "denied")
    }

    // MARK: With the whole app

    @MainActor struct AppFixture {
        let root: URL
        let state: AppState
        let one: Space
        let two: Space
        let tab: BrowserTab
        var center: InboxCenter { state.inbox }
    }

    /// Two Spaces; "two" has a web tab on about:blank and asks before agents act. "one" is selected.
    private func makeApp() throws -> AppFixture {
        MainRunLoopGuard.start
        let root = TestAppState.makeRoot()
        let store = SpaceStore(paths: Paths(root: root))
        let blank = URL(string: "about:blank")!
        let oneTab = BrowserTab.web(blank, title: "page")
        let tab = BrowserTab.web(blank, title: "shop")
        let one = Space(name: "one", slug: "one", colorHex: "#5E81F4", tabs: [oneTab], selectedTabID: oneTab.id)
        var two = Space(name: "two", slug: "two", colorHex: "#F45E81", tabs: [tab], selectedTabID: tab.id)
        two.agentPolicy = .ask
        try store.save(one)
        try store.save(two)
        try store.save(AppStateFile(spaceOrder: [one.id, two.id], selectedSpaceID: one.id))
        let state = TestAppState.make(root: root)
        state.inbox.appIsActive = { false }
        state.inbox.onArrival = { _ in }
        state.inbox.onChange = {}
        state.inbox.requestAttention = {}
        return AppFixture(root: root, state: state, one: one, two: two, tab: tab)
    }

    private func tearDown(_ f: AppFixture) {
        TestAppState.shutDown(f.state)
        try? FileManager.default.removeItem(at: f.root)
    }

    private func appWaiting(_ f: AppFixture) -> [InboxEntry] {
        f.center.inbox.visible.filter { if case .approval = $0.kind { true } else { false } }
    }

    private func appRequest(_ f: AppFixture) -> AgentApprovals.Request {
        var request = clickRequest(tabID: f.tab.id)
        let (state, tabID, spaceID) = (f.state, f.tab.id, f.two.id)
        request.showTab = { [weak state] in state?.showTab(tabID, in: spaceID) }
        return request
    }

    @Test func appWiresTheInboxIn() async throws {
        let f = try makeApp()
        defer { tearDown(f) }
        #expect(f.state.approvals.presenter != nil)
        let answer = Task { @MainActor in await f.state.approvals.check(click, space: f.two, request: appRequest(f)) }
        try await waitUntil("the entry") { !appWaiting(f).isEmpty }
        let entry = try #require(appWaiting(f).first)
        #expect(entry.tabID == f.tab.id && entry.spaceID == f.two.id)
        f.center.decideApproval(entry.id, .approved)
        #expect(await answer.value.logValue == "approved")
    }

    /// Show Tab selects the tab (and its Space): that counts as going to the tab, which must not
    /// take the approval away. It keeps waiting until answered.
    @Test func showingTheTabKeepsTheApproval() async throws {
        let f = try makeApp()
        defer { tearDown(f) }
        let answer = Task { @MainActor in await f.state.approvals.check(click, space: f.two, request: appRequest(f)) }
        try await waitUntil("the entry") { !appWaiting(f).isEmpty }
        let entry = try #require(appWaiting(f).first)

        f.center.showApprovalTab(entry.id)
        #expect(f.state.selectedSpaceID == f.two.id)
        #expect(f.state.selectedTab?.id == f.tab.id)
        // Selecting the tab again (as a click in it would) changes nothing either.
        f.state.selectTab(f.tab.id)
        f.center.wentToTerminal(f.tab.id)
        #expect(appWaiting(f).map(\.id) == [entry.id])

        f.center.decideApproval(entry.id, .denied)
        #expect(await answer.value.logValue == "denied")

        // Showing the tab made a web view with Space two's persistent data store: remove it again.
        f.state.web.removeControllers(for: [f.tab.id])
        try? await Task.sleep(for: .seconds(1))
        try? await WKWebsiteDataStore.remove(forIdentifier: f.two.id)
    }

    @Test func closingTheTabDenies() async throws {
        let f = try makeApp()
        defer { tearDown(f) }
        let answer = Task { @MainActor in await f.state.approvals.check(click, space: f.two, request: appRequest(f)) }
        try await waitUntil("the entry") { !appWaiting(f).isEmpty }
        f.state.closeTab(f.tab.id, in: f.two.id, confirmIfBusy: false)
        #expect(await answer.value.logValue == "denied")
        #expect(appWaiting(f).isEmpty)
    }

    @Test func deletingTheSpaceDenies() async throws {
        let f = try makeApp()
        defer { tearDown(f) }
        // One for the tab, one without a tab (as an artifact prompt has).
        let withTab = Task { @MainActor in await f.state.approvals.check(click, space: f.two, request: appRequest(f)) }
        let withoutTab = Task { @MainActor in await f.state.approvals.check(click, space: f.two, request: clickRequest()) }
        try await waitUntil("two entries") { appWaiting(f).count == 2 }
        f.state.deleteSpace(f.two.id)
        #expect(await withTab.value.logValue == "denied")
        #expect(await withoutTab.value.logValue == "denied")
        #expect(appWaiting(f).isEmpty)
        // The Space's website data is removed a second later; let that happen inside the test.
        try await Task.sleep(for: .milliseconds(1500))
    }

    /// A request for a tab or Space that is already gone is denied at once, without an entry.
    @Test func goneTabOrSpaceIsDenied() async throws {
        let f = try makeApp()
        defer { tearDown(f) }
        var goneTab = clickRequest(tabID: UUID())
        goneTab.showTab = {}
        #expect(await f.state.approvals.check(click, space: f.two, request: goneTab).logValue == "denied")
        var goneSpace = askingSpace()
        goneSpace.name = "gone"
        #expect(await f.state.approvals.check(click, space: goneSpace, request: clickRequest()).logValue == "denied")
        #expect(appWaiting(f).isEmpty)
    }
}
}
