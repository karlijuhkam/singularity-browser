import Foundation
import Testing
@testable import SingularityCore

/// Which terminals count as running agents, and the per-Space numbers.
@Suite struct RunningAgentsTests {
    let defaults = RunningAgents.agentNames(launcherCommands: [])

    @Test func defaultsAlwaysThere() {
        #expect(defaults == ["claude", "codex"])
    }

    @Test func runnersAreNotAgents() {
        let npx = RunningAgents.agentNames(launcherCommands: ["npx @google/gemini-cli"])
        #expect(npx.contains("gemini-cli"))
        #expect(!npx.contains("npx"))
        let cd = RunningAgents.agentNames(launcherCommands: ["cd ~/x && claude --resume"])
        #expect(!cd.contains("cd"))
        #expect(cd == defaults)
        let nvm = RunningAgents.agentNames(launcherCommands: ["nvm use 20 && aider"])
        #expect(nvm.contains("aider"))
        #expect(!nvm.contains("nvm"))
        let sudo = RunningAgents.agentNames(launcherCommands: ["sudo env FOO=1 bunx -y opencode"])
        #expect(sudo == defaults.union(["opencode"]))
        let pipx = RunningAgents.agentNames(launcherCommands: ["pipx run aider"])
        #expect(pipx == defaults.union(["aider"]))
        #expect(RunningAgents.agentNames(launcherCommands: ["npx"]) == defaults)
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
