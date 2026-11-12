import Foundation
import Testing
@testable import SingularityCore

@Suite struct InboxTextTests {
    @Test func cleanStripsControlAndDirectionCharacters() {
        #expect(InboxText.clean("a\u{1b}[31mb\u{202E}c\u{200B}d\n\n  e", limit: 100) == "a[31mbcd e")
    }
    @Test func cleanShortens() {
        #expect(InboxText.clean(String(repeating: "x", count: 1_000_000), limit: 600).count == 600)
        #expect(InboxText.clean(String(repeating: "x", count: 700), limit: 600).hasSuffix("…"))
    }
    @Test func cleanBlockKeepsNewlines() {
        #expect(InboxText.cleanBlock("a\n\tb\u{7}", limit: 100) == "a\n\tb")
    }
}

@Suite struct InboxRulesTests {
    @Test func summarisePicksTheMostUrgent() {
        let r = [StatusRecord(id: "", state: .working, kind: nil, app: "claude", message: nil),
                 StatusRecord(id: "sub/1", state: .blocked, kind: .permission, app: nil, message: "Run npm?")]
        #expect(InboxRules.summarise(r)?.state == .blocked)
        #expect(InboxRules.summarise([]) == nil)
    }
    /// blocked > error > working > done > idle. Working outranks done: Claude Code keeps records
    /// for subagents and tasks, and a finished child must not make a busy tab look done.
    @Test func summariseRanksWorkingAboveDone() {
        func top(_ states: [ProgramState]) -> ProgramState? {
            InboxRules.summarise(states.enumerated().map {
                StatusRecord(id: $0.offset == 0 ? "" : "sub/\($0.offset)", state: $0.element, kind: nil, app: nil, message: nil)
            })?.state
        }
        #expect(top([.working, .done]) == .working)
        #expect(top([.done, .working]) == .working)
        #expect(top([.done, .idle]) == .done)
        #expect(top([.blocked, .working]) == .blocked)
        #expect(top([.working, .error]) == .error)
        #expect(top([.error, .blocked]) == .blocked)
        #expect(top([.idle, .working, .done]) == .working)
    }
    /// The tab's main record still working while a subagent's record says done: the tab is working.
    @Test func finishedSubagentDoesNotEndTheTurn() {
        var inbox = Inbox()
        let tab = UUID()
        let facts = TabFacts(tabID: tab, spaceID: UUID(), foregroundProgram: "claude", isLookedAt: false)
        let records = [StatusRecord(id: "", state: .working, kind: nil, app: "claude", message: nil),
                       StatusRecord(id: "task/1", state: .done, kind: nil, app: "claude", message: "Subtask done")]
        let change = inbox.apply(.status(records), tab: facts, agent: "Claude Code", now: Date())
        #expect(change == .changed)
        #expect(inbox.entries.isEmpty)
        #expect(inbox.workingTabs == [tab])
    }
    @Test func summariseTieGoesToShorterId() {
        let r = [StatusRecord(id: "sub/1", state: .done, kind: nil, app: nil, message: nil),
                 StatusRecord(id: "a", state: .done, kind: nil, app: nil, message: nil)]
        #expect(InboxRules.summarise(r)?.id == "a")
    }
    @Test func agentNames() {
        #expect(InboxRules.agentName(statusApp: "Claude", foregroundProgram: "node") == "Claude Code")
        #expect(InboxRules.agentName(statusApp: "claude-code", foregroundProgram: nil) == "Claude Code")
        #expect(InboxRules.agentName(statusApp: nil, foregroundProgram: "hermes") == "Hermes")
        #expect(InboxRules.agentName(statusApp: nil, foregroundProgram: "aider") == "aider")
        #expect(InboxRules.agentName(statusApp: nil, foregroundProgram: nil) == "Agent")
    }
    @Test func lookedAtNeedsAllThree() {
        #expect(InboxRules.isLookedAt(appIsActive: true, windowIsKey: true, tabIsOnScreen: true))
        #expect(!InboxRules.isLookedAt(appIsActive: false, windowIsKey: true, tabIsOnScreen: true))
    }
    @Test func heldKinds() {
        let q = InboxEntry(kind: .question([]), spaceID: UUID(), tabID: nil, agent: "Claude Code", message: nil, arrived: Date())
        let d = InboxEntry(kind: .done, spaceID: UUID(), tabID: nil, agent: "Claude Code", message: nil, arrived: Date())
        #expect(q.isHeld && !d.isHeld)
    }
}

@Suite struct InboxListTests {
    let space = UUID()
    let tab = UUID()
    let now = Date(timeIntervalSince1970: 1_000)

    func facts(looked: Bool = false, program: String? = "claude", tab: UUID? = nil, space: UUID? = nil) -> TabFacts {
        TabFacts(tabID: tab ?? self.tab, spaceID: space ?? self.space, foregroundProgram: program, isLookedAt: looked)
    }
    func rec(_ state: ProgramState, kind: InboxWaitingReason? = nil, message: String? = nil) -> TerminalSignal {
        .status([StatusRecord(id: "", state: state, kind: kind, app: "claude", message: message)])
    }
    func at(_ s: Double) -> Date { Date(timeIntervalSince1970: 1_000 + s) }
    func name(_ e: InboxEntry) -> String {
        switch e.kind {
        case .approval: "approval"
        case .permission: "permission"
        case .question: "question"
        case .waiting: "waiting"
        case .done: "done"
        }
    }
    func approval() -> InboxApproval { InboxApproval(actor: "Claude Code", action: "click", detail: "Buy") }

    @Test func blockedCreatesWaitingEntry() {
        var inbox = Inbox()
        let change = inbox.apply(rec(.blocked, kind: .question, message: "Pick one"), tab: facts(), agent: "Claude Code", now: now)
        guard case .added = change else { Issue.record("expected added"); return }
        #expect(inbox.visible.count == 1)
        #expect(inbox.visible[0].kind == .waiting(.question))
        #expect(inbox.visible[0].message == "Pick one")
    }
    @Test func workingRemovesEntryAndCounts() {
        var inbox = Inbox()
        _ = inbox.apply(rec(.blocked), tab: facts(), agent: "A", now: now)
        _ = inbox.apply(rec(.working), tab: facts(), agent: "A", now: now)
        #expect(inbox.visible.isEmpty)
        #expect(inbox.workingCount == 1)
    }
    @Test func doneThenIdleRemoves() {
        var inbox = Inbox()
        _ = inbox.apply(rec(.done, message: "ok"), tab: facts(), agent: "A", now: now)
        #expect(inbox.visible.first?.kind == .done)
        _ = inbox.apply(rec(.idle), tab: facts(), agent: "A", now: now)
        #expect(inbox.visible.isEmpty)
        #expect(inbox.workingCount == 0)
    }
    @Test func noRecordsRemovesEntryAndWorking() {
        var inbox = Inbox()
        _ = inbox.apply(rec(.working), tab: facts(), agent: "A", now: now)
        _ = inbox.apply(.status([]), tab: facts(), agent: "A", now: now)
        #expect(inbox.workingCount == 0)
    }
    @Test func errorIsWaiting() {
        var inbox = Inbox()
        _ = inbox.apply(rec(.error, message: "boom"), tab: facts(), agent: "A", now: now)
        #expect(inbox.visible.first?.kind == .waiting(.error))
    }
    @Test func blockedWithoutKindIsAttention() {
        var inbox = Inbox()
        _ = inbox.apply(rec(.blocked), tab: facts(), agent: "A", now: now)
        #expect(inbox.visible.first?.kind == .waiting(.attention))
        #expect(inbox.visible.first?.message == nil)
    }
    @Test func nothingWhileLookedAt() {
        var inbox = Inbox()
        #expect(inbox.apply(rec(.blocked), tab: facts(looked: true), agent: "A", now: now) == .none)
        #expect(inbox.visible.isEmpty)
    }
    @Test func workingStillCountedWhileLookedAt() {
        var inbox = Inbox()
        _ = inbox.apply(rec(.working), tab: facts(looked: true), agent: "A", now: now)
        #expect(inbox.workingCount == 1)
    }
    @Test func sameStateDoesNotAnnounceTwice() {
        var inbox = Inbox()
        _ = inbox.apply(rec(.blocked, kind: .question, message: "One"), tab: facts(), agent: "A", now: now)
        let arrived = inbox.visible[0].arrived
        let change = inbox.apply(rec(.blocked, kind: .question, message: "Two"), tab: facts(), agent: "A", now: at(60))
        #expect(change == .changed)
        #expect(inbox.visible.count == 1)
        #expect(inbox.visible[0].arrived == arrived)
        #expect(inbox.visible[0].message == "Two")
    }
    @Test func differentStateReplacesAndAnnounces() {
        var inbox = Inbox()
        _ = inbox.apply(rec(.blocked), tab: facts(), agent: "A", now: now)
        let change = inbox.apply(rec(.done), tab: facts(), agent: "A", now: at(5))
        guard case .added = change else { Issue.record("expected added"); return }
        #expect(inbox.entries.count == 1)
        #expect(inbox.visible[0].kind == .done)
    }
    @Test func lookedAtWithOtherStateDropsStaleEntry() {
        var inbox = Inbox()
        _ = inbox.apply(rec(.blocked), tab: facts(), agent: "A", now: now)
        #expect(inbox.apply(rec(.done), tab: facts(looked: true), agent: "A", now: now) == .changed)
        #expect(inbox.visible.isEmpty)
    }
    @Test func messageIsCleaned() {
        var inbox = Inbox()
        _ = inbox.apply(rec(.blocked, message: "a\u{1b}[31m\u{202E}b"), tab: facts(), agent: "A", now: now)
        #expect(inbox.visible[0].message == "a[31mb")
    }
    @Test func bellNeedsAForegroundProgram() {
        var inbox = Inbox()
        #expect(inbox.apply(.bell, tab: facts(program: nil), agent: "A", now: now) == .none)
        guard case .added = inbox.apply(.bell, tab: facts(program: "hermes"), agent: "Hermes", now: now) else {
            Issue.record("expected added"); return
        }
        #expect(inbox.visible[0].kind == .waiting(.attention))
    }
    @Test func bellIgnoredAfterStatus() {
        var inbox = Inbox()
        _ = inbox.apply(rec(.working), tab: facts(), agent: "A", now: now)
        #expect(inbox.apply(.bell, tab: facts(), agent: "A", now: now) == .none)
        _ = inbox.apply(.programExited, tab: facts(program: nil), agent: "A", now: now)
        guard case .added = inbox.apply(.bell, tab: facts(program: "vim"), agent: "vim", now: now) else {
            Issue.record("expected added"); return
        }
    }
    @Test func notificationIgnoredAfterStatus() {
        var inbox = Inbox()
        _ = inbox.apply(rec(.idle), tab: facts(), agent: "A", now: now)
        #expect(inbox.apply(.notification(title: "T", body: "B"), tab: facts(), agent: "A", now: now) == .none)
    }
    @Test func repeatedBellDoesNotAnnounceTwice() {
        var inbox = Inbox()
        _ = inbox.apply(.bell, tab: facts(), agent: "A", now: now)
        #expect(inbox.apply(.bell, tab: facts(), agent: "A", now: at(1)) == .none)
        #expect(inbox.entries.count == 1)
    }
    @Test func notificationUsesBodyThenTitle() {
        var inbox = Inbox()
        _ = inbox.apply(.notification(title: "Title", body: "Body"), tab: facts(), agent: "A", now: now)
        #expect(inbox.visible[0].message == "Body")
        var other = Inbox()
        _ = other.apply(.notification(title: "Title", body: "  "), tab: facts(), agent: "A", now: now)
        #expect(other.visible[0].message == "Title")
    }
    @Test func notificationMessageUsesTheMessageLimit() {
        var inbox = Inbox()
        _ = inbox.apply(.notification(title: "T", body: String(repeating: "x", count: 1000)), tab: facts(), agent: "A", now: now)
        #expect(inbox.visible[0].message?.count == InboxText.messageLimit)
        #expect(inbox.visible[0].message?.hasSuffix("…") == true)
    }
    @Test func notificationWhileLookedAtMakesNothing() {
        var inbox = Inbox()
        #expect(inbox.apply(.notification(title: "T", body: "B"), tab: facts(looked: true), agent: "A", now: now) == .none)
    }
    @Test func heldHidesLevelOne() {
        var inbox = Inbox()
        _ = inbox.apply(rec(.blocked, kind: .question), tab: facts(), agent: "A", now: now)
        let held = inbox.hold(.question([]), tab: facts(), agent: "A", now: at(1))
        #expect(inbox.visible.map(\.id) == [held!.id])
        #expect(inbox.count == 1)
        #expect(inbox.entries.count == 2)
    }
    @Test func holdRefusedWhileLookedAt() {
        var inbox = Inbox()
        #expect(inbox.hold(.question([]), tab: facts(looked: true), agent: "A", now: now) == nil)
        #expect(inbox.entries.isEmpty)
    }
    @Test func severalHeldPerTab() {
        var inbox = Inbox()
        _ = inbox.hold(.permission(tool: "Bash", input: "ls", isComplete: true), tab: facts(), agent: "A", now: now)
        _ = inbox.hold(.permission(tool: "Bash", input: "pwd", isComplete: true), tab: facts(), agent: "A", now: at(1))
        #expect(inbox.visible.count == 2)
    }
    @Test func workingTabWithVisibleEntryIsNotCountedAsWorking() {
        var inbox = Inbox()
        _ = inbox.apply(rec(.working), tab: facts(), agent: "A", now: now)
        _ = inbox.hold(.question([]), tab: facts(), agent: "A", now: now)
        #expect(inbox.workingCount == 0)
    }
    @Test func wentToTerminalReturnsHeldAndKeepsApprovals() {
        var inbox = Inbox()
        let held = inbox.hold(.permission(tool: "Bash", input: "ls", isComplete: true), tab: facts(), agent: "A", now: now)!
        _ = inbox.apply(rec(.blocked), tab: facts(), agent: "A", now: now)
        let appr = inbox.addApproval(approval(), spaceID: space, tabID: tab, deadline: at(120), now: now)
        let removed = inbox.wentToTerminal(tab)
        #expect(removed.map(\.id) == [held.id])
        #expect(inbox.visible.map(\.id) == [appr.id])
        #expect(inbox.entries.count == 1)
    }
    @Test func tabClosedReturnsHeldAndApprovals() {
        var inbox = Inbox()
        let held = inbox.hold(.question([]), tab: facts(), agent: "A", now: now)!
        let appr = inbox.addApproval(approval(), spaceID: space, tabID: tab, deadline: at(120), now: now)
        _ = inbox.apply(rec(.working), tab: facts(), agent: "A", now: now)
        _ = inbox.apply(rec(.done), tab: facts(tab: UUID()), agent: "A", now: now)
        let removed = inbox.tabClosed(tab)
        #expect(Set(removed.map(\.id)) == [held.id, appr.id])
        #expect(inbox.workingCount == 0)
        #expect(inbox.entries.count == 1)
    }
    @Test func demoteLeavesAWaitingEntry() {
        var inbox = Inbox()
        let held = inbox.hold(.question([]), tab: facts(), agent: "A", now: now)!
        inbox.demote(held.id)
        #expect(inbox.visible.count == 1)
        #expect(inbox.visible[0].kind == .waiting(.question))
        #expect(inbox.visible[0].arrived == held.arrived)
        #expect(inbox.visible[0].tabID == tab)
    }
    @Test func demoteForPermission() {
        var inbox = Inbox()
        let held = inbox.hold(.permission(tool: "Bash", input: "ls", isComplete: true), tab: facts(), agent: "A", now: now)!
        inbox.demote(held.id)
        #expect(inbox.visible[0].kind == .waiting(.permission))
    }
    @Test func stopMessageLandsOnDoneEntry() {
        var inbox = Inbox()
        inbox.noteLastMessage("All tests pass", tabID: tab)
        _ = inbox.apply(rec(.done, message: "short"), tab: facts(), agent: "A", now: now)
        #expect(inbox.visible[0].message == "All tests pass")

        var other = Inbox()
        _ = other.apply(rec(.done, message: "short"), tab: facts(), agent: "A", now: now)
        #expect(other.visible[0].message == "short")
        other.noteLastMessage("All tests pass", tabID: tab)
        #expect(other.visible[0].message == "All tests pass")
        // a later status record does not bring the short text back
        _ = other.apply(rec(.done, message: "short"), tab: facts(), agent: "A", now: at(1))
        #expect(other.visible[0].message == "All tests pass")
    }
    @Test func noteIsForgottenWhenWorkingAgain() {
        var inbox = Inbox()
        inbox.noteLastMessage("Old", tabID: tab)
        _ = inbox.apply(rec(.working), tab: facts(), agent: "A", now: now)
        _ = inbox.apply(rec(.done, message: "New"), tab: facts(), agent: "A", now: at(1))
        #expect(inbox.visible[0].message == "New")
    }
    @Test func noteIsForgottenWhenProgramExits() {
        var inbox = Inbox()
        inbox.noteLastMessage("Old", tabID: tab)
        _ = inbox.apply(.programExited, tab: facts(program: nil), agent: "A", now: now)
        _ = inbox.apply(rec(.done, message: "New"), tab: facts(), agent: "A", now: at(1))
        #expect(inbox.visible[0].message == "New")
    }
    @Test func noteIsCleaned() {
        var inbox = Inbox()
        inbox.noteLastMessage("a\u{7}\n\n b", tabID: tab)
        _ = inbox.apply(rec(.done), tab: facts(), agent: "A", now: now)
        #expect(inbox.visible[0].message == "a b")
    }
    @Test func noteReleasesHeldEntriesOfThatTabOnly() {
        var inbox = Inbox()
        let q = inbox.hold(.question([]), tab: facts(), agent: "A", now: now)!
        let p = inbox.hold(.permission(tool: "Bash", input: "ls", isComplete: true), tab: facts(), agent: "A", now: now)!
        let other = inbox.hold(.question([]), tab: facts(tab: UUID()), agent: "A", now: now)!
        inbox.noteLastMessage("Done", tabID: tab)
        #expect(Set(inbox.takeReleased().map(\.id)) == [q.id, p.id])
        #expect(inbox.takeReleased().isEmpty)
        #expect(inbox.entries.map(\.id) == [other.id])
    }
    @Test func workingReleasesHeldPermissionButNotQuestion() {
        var inbox = Inbox()
        let q = inbox.hold(.question([]), tab: facts(), agent: "A", now: now)!
        let p = inbox.hold(.permission(tool: "Bash", input: "ls", isComplete: true), tab: facts(), agent: "A", now: now)!
        _ = inbox.apply(rec(.working), tab: facts(), agent: "A", now: now)
        #expect(inbox.takeReleased().map(\.id) == [p.id])
        #expect(inbox.entries.map(\.id) == [q.id])
    }
    @Test func blockedReleasesNothing() {
        var inbox = Inbox()
        _ = inbox.hold(.permission(tool: "Bash", input: "ls", isComplete: true), tab: facts(), agent: "A", now: now)
        _ = inbox.apply(rec(.blocked, kind: .permission), tab: facts(), agent: "A", now: now)
        #expect(inbox.takeReleased().isEmpty)
    }
    @Test func doneReleasesHeldQuestion() {
        var inbox = Inbox()
        let q = inbox.hold(.question([]), tab: facts(), agent: "A", now: now)!
        let p = inbox.hold(.permission(tool: "Bash", input: "ls", isComplete: true), tab: facts(), agent: "A", now: now)!
        _ = inbox.apply(rec(.done), tab: facts(), agent: "A", now: now)
        #expect(Set(inbox.takeReleased().map(\.id)) == [q.id, p.id])
        #expect(inbox.entries.count == 1)   // just the done entry
    }
    @Test func idleAndNoRecordsReleaseHeld() {
        var inbox = Inbox()
        let q = inbox.hold(.question([]), tab: facts(), agent: "A", now: now)!
        _ = inbox.apply(rec(.idle), tab: facts(), agent: "A", now: now)
        #expect(inbox.takeReleased().map(\.id) == [q.id])
        let p = inbox.hold(.permission(tool: "Bash", input: "ls", isComplete: true), tab: facts(), agent: "A", now: now)!
        _ = inbox.apply(.status([]), tab: facts(), agent: "A", now: now)
        #expect(inbox.takeReleased().map(\.id) == [p.id])
    }
    @Test func programExitedReleasesHeld() {
        var inbox = Inbox()
        let q = inbox.hold(.question([]), tab: facts(), agent: "A", now: now)!
        let p = inbox.hold(.permission(tool: "Bash", input: "ls", isComplete: true), tab: facts(), agent: "A", now: now)!
        _ = inbox.apply(.programExited, tab: facts(program: nil), agent: "A", now: now)
        #expect(Set(inbox.takeReleased().map(\.id)) == [q.id, p.id])
        #expect(inbox.entries.isEmpty)
    }
    @Test func releaseIgnoresOtherTabsAndApprovals() {
        var inbox = Inbox()
        let other = inbox.hold(.permission(tool: "Bash", input: "ls", isComplete: true), tab: facts(tab: UUID()), agent: "A", now: now)!
        let appr = inbox.addApproval(approval(), spaceID: space, tabID: tab, deadline: at(120), now: now)
        _ = inbox.apply(rec(.working), tab: facts(), agent: "A", now: now)
        _ = inbox.apply(.programExited, tab: facts(program: nil), agent: "A", now: now)
        #expect(inbox.takeReleased().isEmpty)
        #expect(Set(inbox.entries.map(\.id)) == [other.id, appr.id])
    }
    @Test func orderIsApprovalsHeldWaitingDone() {
        var inbox = Inbox()
        _ = inbox.apply(rec(.done), tab: facts(tab: UUID()), agent: "A", now: at(1))
        _ = inbox.apply(rec(.blocked), tab: facts(tab: UUID()), agent: "A", now: at(2))
        _ = inbox.hold(.permission(tool: "Bash", input: "ls", isComplete: true), tab: facts(tab: UUID()), agent: "A", now: at(3))
        _ = inbox.addApproval(approval(), spaceID: space, tabID: nil, deadline: at(200), now: at(4))
        #expect(inbox.visible.map(name) == ["approval", "permission", "waiting", "done"])
    }
    @Test func oldestFirstWithinAGroup() {
        var inbox = Inbox()
        let late = inbox.hold(.question([]), tab: facts(tab: UUID()), agent: "A", now: at(9))!
        let early = inbox.hold(.question([]), tab: facts(tab: UUID()), agent: "A", now: at(2))!
        #expect(inbox.visible.map(\.id) == [early.id, late.id])
    }
    @Test func countsPerSpace() {
        var inbox = Inbox()
        let other = UUID()
        _ = inbox.apply(rec(.blocked), tab: facts(tab: UUID()), agent: "A", now: now)
        _ = inbox.apply(rec(.done), tab: facts(tab: UUID()), agent: "A", now: now)
        _ = inbox.apply(rec(.done), tab: facts(tab: UUID(), space: other), agent: "A", now: now)
        #expect(inbox.count(spaceID: space) == 2)
        #expect(inbox.count(spaceID: other) == 1)
        #expect(inbox.count == 3)
    }
    @Test func removeAndSetDeadline() {
        var inbox = Inbox()
        let appr = inbox.addApproval(approval(), spaceID: space, tabID: tab, deadline: at(10), now: now)
        inbox.setDeadline(appr.id, at(99))
        #expect(inbox.entries[0].deadline == at(99))
        #expect(inbox.remove(appr.id)?.id == appr.id)
        #expect(inbox.remove(appr.id) == nil)
    }
}

/// What the app hands the inbox from SwiftTerm: OSC 777 / OSC 9 payloads and OSC 7501 record fields.
@Suite struct TerminalSignalParsingTests {
    private func bytes(_ s: String) -> [UInt8] { Array(s.utf8) }

    @Test func osc777NotifyGivesTitleAndBody() {
        #expect(TerminalNotificationPayload.signal(code: 777, payload: bytes("notify;Build;done; all green"))
                == .notification(title: "Build", body: "done; all green"))
        #expect(TerminalNotificationPayload.signal(code: 777, payload: bytes("notify;;hello"))
                == .notification(title: "", body: "hello"))
    }
    @Test func osc777OtherThanNotifyIsIgnored() {
        #expect(TerminalNotificationPayload.signal(code: 777, payload: bytes("notify;only-title")) == nil)
        #expect(TerminalNotificationPayload.signal(code: 777, payload: bytes("precmd;x;y")) == nil)
    }
    @Test func osc9TextIsTheBody() {
        #expect(TerminalNotificationPayload.signal(code: 9, payload: bytes("Hermes: your turn"))
                == .notification(title: "", body: "Hermes: your turn"))
    }
    @Test func osc9ProgressAndNumbersAreIgnored() {
        #expect(TerminalNotificationPayload.signal(code: 9, payload: bytes("4;1;50")) == nil)
        #expect(TerminalNotificationPayload.signal(code: 9, payload: bytes("4;Hermes")) == nil)
        #expect(TerminalNotificationPayload.signal(code: 9, payload: bytes("2;3")) == nil)
        #expect(TerminalNotificationPayload.signal(code: 9, payload: bytes("")) == nil)
    }
    @Test func osc9NumberedSubCommandsAreIgnored() {
        // ConEmu-style sub-commands; some prompt themes send `9;9;<cwd>` at every prompt.
        #expect(TerminalNotificationPayload.signal(code: 9, payload: bytes("9;/Users/me/project")) == nil)
        #expect(TerminalNotificationPayload.signal(code: 9, payload: bytes("1;500")) == nil)
        #expect(TerminalNotificationPayload.signal(code: 9, payload: bytes("12;text")) == nil)
        // Text that merely starts with a number is still a notification.
        #expect(TerminalNotificationPayload.signal(code: 9, payload: bytes("3 tests failed"))
                == .notification(title: "", body: "3 tests failed"))
    }
    @Test func otherCodesAndBadBytesAreIgnored() {
        #expect(TerminalNotificationPayload.signal(code: 0, payload: bytes("title")) == nil)
        #expect(TerminalNotificationPayload.signal(code: 9, payload: [0xFF, 0xFE, 0x41]) == nil)
    }
    @Test func statusRecordFromTerminalFields() {
        #expect(StatusRecord(terminalID: "", state: "blocked", kind: "permission", app: "claude-code", message: "approve Bash")
                == StatusRecord(id: "", state: .blocked, kind: .permission, app: "claude-code", message: "approve Bash"))
        #expect(StatusRecord(terminalID: "sub/1", state: "done", kind: nil, app: nil, message: nil)
                == StatusRecord(id: "sub/1", state: .done, kind: nil, app: nil, message: nil))
        // An unknown kind is dropped (the entry then says "waiting"); an unknown state drops the record.
        #expect(StatusRecord(terminalID: "", state: "blocked", kind: "dance", app: nil, message: nil)?.kind == nil)
        #expect(StatusRecord(terminalID: "", state: "sleeping", kind: nil, app: nil, message: nil) == nil)
    }
}

@Suite struct InboxNotificationTextTests {
    private func entry(_ kind: InboxKind, agent: String = "Claude Code", message: String? = nil) -> InboxEntry {
        InboxEntry(kind: kind, spaceID: UUID(), tabID: UUID(), agent: agent, message: message, arrived: Date())
    }

    @Test func notificationText() {
        let question = entry(.question([InboxQuestion(question: "Which database?")]))
        let made = InboxNotificationText.make(question, spaceName: "Work")
        #expect(made.title == "Claude Code · Work")
        #expect(made.body == "Which database?")
        #expect(InboxNotificationText.make(entry(.done), spaceName: "Work").body == "Finished")
    }

    @Test func bodyByKind() {
        #expect(InboxNotificationText.make(entry(.permission(tool: "Bash", input: "ls", isComplete: true)), spaceName: "W").body == "Wants to use Bash")
        let approval = InboxApproval(actor: "Claude", action: "click Buy", detail: "d")
        #expect(InboxNotificationText.make(entry(.approval(approval)), spaceName: "W").body == "Wants to click Buy")
        #expect(InboxNotificationText.make(entry(.waiting(.attention)), spaceName: "W").body == "Waiting for you")
        #expect(InboxNotificationText.make(entry(.waiting(.attention), message: "Tests failed"), spaceName: "W").body == "Tests failed")
        #expect(InboxNotificationText.make(entry(.done, message: "All green"), spaceName: "W").body == "All green")
    }

    @Test func untrustedTextIsCleanedAndLimited() {
        let long = String(repeating: "a", count: 500)
        let made = InboxNotificationText.make(entry(.done, agent: "Ev\u{202E}il", message: "x\u{0007}y " + long), spaceName: "Sp\u{200B}ace")
        #expect(made.body.count == InboxText.notificationLimit)
        #expect(!made.body.contains("\u{0007}"))
        #expect(made.title == "Evil · Space")
        let longAgent = InboxNotificationText.make(entry(.done, agent: long), spaceName: "W")
        #expect(longAgent.title.count == 80 + 3 + 1)
    }

    @Test func noSpaceNameLeavesOnlyTheAgent() {
        #expect(InboxNotificationText.make(entry(.done), spaceName: "").title == "Claude Code")
    }
}
