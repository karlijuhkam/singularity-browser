import Testing
import Foundation
@testable import SingularityCore

@Suite struct TerminalBoardTests {
    let tab = UUID()
    let t0 = Date(timeIntervalSince1970: 1000)
    func rec(_ s: ProgramState, kind: InboxWaitingReason? = nil, msg: String? = nil) -> StatusRecord {
        StatusRecord(id: "a", state: s, kind: kind, app: nil, message: msg)
    }

    @Test func nothingReportedIsNil() { #expect(TerminalBoard().row(tab) == nil) }

    @Test func blockedWithKindWaits() {
        var b = TerminalBoard()
        b.apply(.status([rec(.blocked, kind: .question, msg: "  Pick\none ")]), tabID: tab, foregroundProgram: "claude", now: t0)
        #expect(b.row(tab) == .init(state: .waiting, reason: .question, message: "Pick one", since: t0))
    }

    @Test func blockedWithoutKindIsAttention() {
        var b = TerminalBoard()
        b.apply(.status([rec(.blocked)]), tabID: tab, foregroundProgram: nil, now: t0)
        #expect(b.row(tab)?.reason == .attention)
    }

    @Test func errorIsWaitingError() {
        var b = TerminalBoard()
        b.apply(.status([rec(.error, msg: "boom")]), tabID: tab, foregroundProgram: nil, now: t0)
        #expect(b.row(tab)?.state == .waiting)
        #expect(b.row(tab)?.reason == .error)
        #expect(b.row(tab)?.message == "boom")
    }

    @Test func workingDoneIdle() {
        var b = TerminalBoard()
        b.apply(.status([rec(.working)]), tabID: tab, foregroundProgram: nil, now: t0)
        #expect(b.row(tab)?.state == .working)
        b.apply(.status([rec(.done, msg: "ok")]), tabID: tab, foregroundProgram: nil, now: t0)
        #expect(b.row(tab)?.state == .done)
        #expect(b.row(tab)?.message == "ok")
        b.apply(.status([rec(.idle)]), tabID: tab, foregroundProgram: nil, now: t0)
        #expect(b.row(tab)?.state == .idle)
        b.apply(.status([rec(.working)]), tabID: tab, foregroundProgram: nil, now: t0)
        b.apply(.status([]), tabID: tab, foregroundProgram: nil, now: t0)
        #expect(b.row(tab)?.state == .idle)
    }

    @Test func messageIsCutAt1000() {
        var b = TerminalBoard()
        b.apply(.status([rec(.done, msg: String(repeating: "x", count: 2000))]), tabID: tab, foregroundProgram: nil, now: t0)
        #expect(b.row(tab)?.message?.count == 1000)
    }

    @Test func statusTabIgnoresBellAndNotification() {
        var b = TerminalBoard()
        b.apply(.status([rec(.working)]), tabID: tab, foregroundProgram: "claude", now: t0)
        b.apply(.bell, tabID: tab, foregroundProgram: "claude", now: t0)
        b.apply(.notification(title: "t", body: "b"), tabID: tab, foregroundProgram: "claude", now: t0)
        #expect(b.row(tab)?.state == .working)
        b.apply(.status([]), tabID: tab, foregroundProgram: "claude", now: t0)
        b.apply(.bell, tabID: tab, foregroundProgram: "claude", now: t0)
        #expect(b.row(tab)?.state == .idle)
    }

    @Test func notificationWaits() {
        var b = TerminalBoard()
        b.apply(.notification(title: "t", body: " Hello\u{7} "), tabID: tab, foregroundProgram: nil, now: t0)
        #expect(b.row(tab) == .init(state: .waiting, reason: .attention, message: "Hello", since: t0))
    }

    @Test func bellNeedsAProgram() {
        var b = TerminalBoard()
        b.apply(.bell, tabID: tab, foregroundProgram: nil, now: t0)
        #expect(b.row(tab) == nil)
        b.apply(.bell, tabID: tab, foregroundProgram: "vim", now: t0)
        #expect(b.row(tab)?.state == .waiting)
        #expect(b.row(tab)?.message == nil)
    }

    @Test func programExitedIsIdle() {
        var b = TerminalBoard()
        b.apply(.bell, tabID: tab, foregroundProgram: "vim", now: t0)
        b.apply(.programExited, tabID: tab, foregroundProgram: nil, now: t0)
        #expect(b.row(tab)?.state == .idle)
    }

    @Test func sinceChangesOnlyWithStateOrReason() {
        var b = TerminalBoard()
        let t1 = t0.addingTimeInterval(10), t2 = t0.addingTimeInterval(20), t3 = t0.addingTimeInterval(30)
        b.apply(.status([rec(.blocked, kind: .question)]), tabID: tab, foregroundProgram: nil, now: t0)
        b.apply(.status([rec(.blocked, kind: .question, msg: "new")]), tabID: tab, foregroundProgram: nil, now: t1)
        #expect(b.row(tab)?.since == t0)
        #expect(b.row(tab)?.message == "new")
        b.apply(.status([rec(.blocked, kind: .permission)]), tabID: tab, foregroundProgram: nil, now: t2)
        #expect(b.row(tab)?.since == t2)
        b.apply(.status([rec(.working)]), tabID: tab, foregroundProgram: nil, now: t3)
        #expect(b.row(tab)?.since == t3)
    }

    @Test func removeForgets() {
        var b = TerminalBoard()
        b.apply(.status([rec(.working)]), tabID: tab, foregroundProgram: nil, now: t0)
        b.remove(tab)
        #expect(b.row(tab) == nil)
        b.apply(.bell, tabID: tab, foregroundProgram: "vim", now: t0)
        #expect(b.row(tab)?.state == .waiting)
    }
}
