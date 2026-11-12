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
