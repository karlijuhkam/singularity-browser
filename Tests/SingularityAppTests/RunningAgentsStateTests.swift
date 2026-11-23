import Foundation
import Testing
@testable import Singularity
import SingularityCore

extension AppTests {
/// `AppState.runningAgents` and the rail's counts. Terminals are fakes (`terminalHandleOverride`):
/// no test here starts a shell or makes a window key.
@MainActor
@Suite(.serialized) struct RunningAgentsStateTests {
    struct Fixture {
        let root: URL
        let state: AppState
        let spaceID: UUID
        let tabs: [UUID]
    }

    func make(fakes: [UUID: FakeTerminal] = [:], programs: [String?]) throws -> (Fixture, [FakeTerminal?]) {
        MainRunLoopGuard.start
        let root = TestAppState.makeRoot()
        let store = SpaceStore(paths: Paths(root: root))
        var space = Space(name: "Work", slug: "work", colorHex: "#5E81F4", workingDirectory: "~/Developer")
        var ids: [UUID] = []
        var terminals: [FakeTerminal?] = []
        var byID: [UUID: FakeTerminal] = [:]
        for program in programs {
            let tab = BrowserTab.terminal(workingDirectory: "~/Developer")
            space.append(tab)
            ids.append(tab.id)
            // The test's own marker: "-" stands for a tab with no session at all.
            if program == "-" { terminals.append(nil); continue }
            let fake = FakeTerminal()
            fake.foregroundProgram = program == "" ? nil : program
            terminals.append(fake)
            byID[tab.id] = fake
        }
        try store.save(space)
        let state = TestAppState.make(root: root)
        state.terminalHandleOverride = { byID[$0] }
        state.inbox.appIsActive = { false }
        state.inbox.windowIsKey = { false }
        return (Fixture(root: root, state: state, spaceID: space.id, tabs: ids), terminals)
    }

    func finish(_ f: Fixture) {
        TestAppState.shutDown(f.state)
        try? FileManager.default.removeItem(at: f.root)
    }

    @Test func listsOnlyAgentsWithLiveSessions() throws {
        let (f, _) = try make(programs: ["claude", "npm", "-"])
        defer { finish(f) }
        #expect(f.state.runningAgents.map(\.tabID) == [f.tabs[0]])
        #expect(f.state.runningAgentCounts[f.spaceID] == RunningAgents.SpaceCount(count: 1, anyWorking: false))
    }

    @Test func exitedAgentLeaves() throws {
        let (f, fakes) = try make(programs: ["claude"])
        defer { finish(f) }
        #expect(f.state.runningAgents.count == 1)
        fakes[0]?.foregroundProgram = nil
        #expect(f.state.runningAgents.isEmpty)
        #expect(f.state.runningAgentCounts.isEmpty)
    }

    @Test func launcherAddsName() throws {
        let (f, _) = try make(programs: ["aider"])
        defer { finish(f) }
        #expect(f.state.runningAgents.isEmpty)
        f.state.updateSettings { $0.launchers = [Launcher(name: "Aider", command: "aider --yes")] }
        #expect(f.state.runningAgents.map(\.tabID) == [f.tabs[0]])
    }

    @Test func runningRowGoesToTerminal() throws {
        let (f, _) = try make(programs: ["claude"])
        defer { finish(f) }
        // A second Space is in front.
        let other = f.state.createSpace(name: "Other", colorHex: "#FF0000", workingDirectory: "~")
        f.state.selectSpace(other.id)
        #expect(f.state.selectedSpaceID == other.id)
        let signal = TerminalSignal.status([StatusRecord(id: "", state: .blocked, kind: .attention, app: "claude-code", message: "Pick one")])
        f.state.inbox.terminalSignal(signal, tabID: f.tabs[0], spaceID: f.spaceID, foregroundProgram: "claude")
        #expect(f.state.inbox.inbox.visible.contains { $0.tabID == f.tabs[0] })

        f.state.inbox.goToTerminal(tabID: f.tabs[0], spaceID: f.spaceID)

        #expect(f.state.selectedSpaceID == f.spaceID)
        #expect(f.state.space(f.spaceID)?.selectedTabID == f.tabs[0])
        #expect(!f.state.inbox.inbox.visible.contains { $0.tabID == f.tabs[0] })
    }
}
}
