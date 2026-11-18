import Foundation
import Testing
@testable import SingularityCore

/// The sidebar's per-tab mark: which tabs the inbox has something for.
@Suite struct TabAttentionTests {
    let space = UUID()
    let now = Date(timeIntervalSince1970: 1_000)

    func facts(_ tab: UUID) -> TabFacts {
        TabFacts(tabID: tab, spaceID: space, foregroundProgram: "claude", isLookedAt: false)
    }
    func rec(_ state: ProgramState) -> TerminalSignal {
        .status([StatusRecord(id: "", state: state, kind: nil, app: "claude", message: nil)])
    }

    @Test func eachKindMarksItsTab() {
        let (waiting, done, held, approval, quiet) = (UUID(), UUID(), UUID(), UUID(), UUID())
        var inbox = Inbox()
        _ = inbox.apply(rec(.blocked), tab: facts(waiting), agent: "A", now: now)
        _ = inbox.apply(rec(.done), tab: facts(done), agent: "A", now: now)
        _ = inbox.hold(.question([]), tab: facts(held), agent: "A", now: now)
        _ = inbox.addApproval(InboxApproval(actor: "A", action: "click", detail: "Buy"),
                              spaceID: space, tabID: approval, deadline: now.addingTimeInterval(60), now: now)
        _ = inbox.apply(rec(.working), tab: facts(quiet), agent: "A", now: now)
        let marks = inbox.tabAttention
        #expect(marks[waiting] == .needsYou)
        #expect(marks[done] == .done)
        #expect(marks[held] == .needsYou)
        #expect(marks[approval] == .needsYou)
        #expect(marks[quiet] == .working)
    }

    @Test func needsYouOutranksWorkingAndWorkingOutranksDone() {
        let (asking, busy) = (UUID(), UUID())
        var inbox = Inbox()
        // Status is `working` while a question hook is held: the question wins.
        _ = inbox.apply(rec(.working), tab: facts(asking), agent: "A", now: now)
        _ = inbox.hold(.question([]), tab: facts(asking), agent: "A", now: now)
        _ = inbox.apply(rec(.working), tab: facts(busy), agent: "A", now: now)
        #expect(inbox.tabAttention[asking] == .needsYou)
        #expect(inbox.tabAttention[busy] == .working)
        _ = inbox.apply(rec(.idle), tab: facts(busy), agent: "A", now: now)
        #expect(inbox.tabAttention[busy] == nil)
    }

    @Test func waitingOutranksDoneOnTheSameTab() {
        let tab = UUID()
        var inbox = Inbox()
        _ = inbox.apply(rec(.done), tab: facts(tab), agent: "A", now: now)
        _ = inbox.addApproval(InboxApproval(actor: "A", action: "click", detail: "Buy"),
                              spaceID: space, tabID: tab, deadline: now.addingTimeInterval(60), now: now)
        #expect(inbox.tabAttention[tab] == .needsYou)
    }

    @Test func theMarkLeavesWithTheEntry() {
        let tab = UUID()
        var inbox = Inbox()
        _ = inbox.apply(rec(.blocked), tab: facts(tab), agent: "A", now: now)
        _ = inbox.wentToTerminal(tab)
        #expect(inbox.tabAttention.isEmpty)
    }

    @Test func aCollapsedFolderShowsTheStrongestMarkInsideIt() {
        let outer = Folder(name: "Outer")
        let inner = Folder(name: "Inner", parentID: outer.id)
        let other = Folder(name: "Other")
        var a = BrowserTab.terminal(workingDirectory: "~"); a.folderID = inner.id
        var b = BrowserTab.terminal(workingDirectory: "~"); b.folderID = outer.id
        let loose = BrowserTab.terminal(workingDirectory: "~")
        var s = Space(name: "Work", slug: "work", colorHex: "#5E81F4", workingDirectory: "~",
                      folders: [outer, inner, other])
        s.tabs = [a, b, loose]

        #expect(s.attention(ofFolder: outer.id, marks: [b.id: .done]) == .done)
        #expect(s.attention(ofFolder: outer.id, marks: [b.id: .done, a.id: .working]) == .working)
        #expect(s.attention(ofFolder: outer.id, marks: [b.id: .done, a.id: .needsYou]) == .needsYou)
        #expect(s.attention(ofFolder: inner.id, marks: [b.id: .needsYou]) == nil)   // b is in the parent
        #expect(s.attention(ofFolder: other.id, marks: [a.id: .needsYou, loose.id: .needsYou]) == nil)
    }

    @Test func aSpaceCircleCountsOnlyWhatNeedsTheOwner() {
        let (waiting, done, held, approval, busy) = (UUID(), UUID(), UUID(), UUID(), UUID())
        let elsewhere = UUID()
        var inbox = Inbox()
        _ = inbox.apply(rec(.done), tab: facts(done), agent: "A", now: now)
        _ = inbox.apply(rec(.working), tab: facts(busy), agent: "A", now: now)
        #expect(inbox.needsYouCount(spaceID: space) == 0)   // done and working call no one

        _ = inbox.apply(rec(.blocked), tab: facts(waiting), agent: "A", now: now)
        _ = inbox.hold(.question([]), tab: facts(held), agent: "A", now: now)
        _ = inbox.addApproval(InboxApproval(actor: "A", action: "click", detail: "Buy"),
                              spaceID: space, tabID: approval, deadline: now.addingTimeInterval(60), now: now)
        _ = inbox.addApproval(InboxApproval(actor: "A", action: "click", detail: "Buy"),
                              spaceID: elsewhere, tabID: UUID(), deadline: now.addingTimeInterval(60), now: now)
        #expect(inbox.needsYouCount(spaceID: space) == 3)
        #expect(inbox.needsYouCount(spaceID: elsewhere) == 1)

        _ = inbox.wentToTerminal(waiting)
        #expect(inbox.needsYouCount(spaceID: space) == 2)
    }
}
