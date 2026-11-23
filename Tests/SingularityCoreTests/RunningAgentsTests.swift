import Foundation
import Testing
@testable import SingularityCore

/// Which terminals count as running agents, and the per-Space numbers.
@Suite struct RunningAgentsTests {
    let defaults = RunningAgents.agentNames(launcherCommands: [])

    @Test func defaultsAlwaysThere() {
        #expect(defaults == ["claude", "codex"])
    }

    @Test func launcherFirstWord() {
        let names = RunningAgents.agentNames(launcherCommands: ["claude --resume", "FOO=1 /opt/bin/Aider --x", "  ", "gemini"])
        #expect(names.contains("aider"))
        #expect(names.contains("gemini"))
        #expect(names.contains("claude"))
        #expect(names.contains("codex"))
        #expect(names.count == 4)
    }

    @Test func scriptExtensionIsIgnored() {
        #expect(RunningAgents.isAgent(program: "codex.js", names: defaults))
        #expect(!RunningAgents.isAgent(program: "vim", names: defaults))
        #expect(!RunningAgents.isAgent(program: nil, names: defaults))
        #expect(!RunningAgents.isAgent(program: "", names: defaults))
    }

    @Test func caseInsensitive() {
        #expect(RunningAgents.isAgent(program: "Claude", names: defaults))
    }

    @Test func rowsFollowSpaceOrderAndNeedAnAgentInFront() {
        let t1 = BrowserTab.terminal(workingDirectory: "~")
        let t2 = BrowserTab.terminal(workingDirectory: "~")
        let t3 = BrowserTab.terminal(workingDirectory: "~")
        let t4 = BrowserTab.terminal(workingDirectory: "~")
        let web = BrowserTab.web(URL(string: "https://example.com")!)
        var a = Space(name: "A", slug: "a", colorHex: "#000000")
        a.tabs = [t1, web, t2, t3]
        var b = Space(name: "B", slug: "b", colorHex: "#000000")
        b.tabs = [t4]
        let programs: [UUID: String] = [t1.id: "claude", t2.id: "vim", t4.id: "codex", web.id: "claude"]
        let rows = RunningAgents.rows(spaces: [b, a], names: defaults,
                                      program: { programs[$0] },
                                      state: { $0 == t1.id ? .working : nil })
        #expect(rows.map(\.tabID) == [t4.id, t1.id])
        #expect(rows.map(\.spaceID) == [b.id, a.id])
        #expect(rows.map(\.state) == [.unknown, .working])
    }

    @Test func countsPerSpace() {
        let (a, b) = (UUID(), UUID())
        let rows = [
            RunningAgents.Row(tabID: UUID(), spaceID: a, state: .working),
            RunningAgents.Row(tabID: UUID(), spaceID: a, state: .idle),
            RunningAgents.Row(tabID: UUID(), spaceID: b, state: .idle),
        ]
        let counts = RunningAgents.counts(rows)
        #expect(counts[a] == RunningAgents.SpaceCount(count: 2, anyWorking: true))
        #expect(counts[b] == RunningAgents.SpaceCount(count: 1, anyWorking: false))
        #expect(counts[UUID()] == nil)
    }
}
