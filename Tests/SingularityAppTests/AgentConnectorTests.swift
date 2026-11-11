import AppKit
import Foundation
import SingularityCore
import Testing
@testable import Singularity

/// A shell that never runs anything: it records each command line and answers from a script.
/// `onRun` may also write files (an agent's `mcp add` changing its config).
private actor FakeShell: AgentShell {
    typealias Answer = (exitCode: Int32, output: String, timedOut: Bool)
    private(set) var lines: [String] = []
    private let onRun: @Sendable (String) -> Answer

    init(onRun: @escaping @Sendable (String) -> Answer = { _ in (0, "", false) }) {
        self.onRun = onRun
    }

    func run(_ commandLine: String) async -> Answer {
        lines.append(commandLine)
        return onRun(commandLine)
    }
}

private let launcher = "/Applications/Singularity.app/Contents/MacOS/singularity-mcp"

/// A fresh, empty folder standing in for the home folder.
private func makeHome() throws -> URL {
    let home = FileManager.default.temporaryDirectory.appending(path: "agent-connector-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    return home
}

private func writeClaudeConfig(home: URL, command: String) throws {
    let json = #"{"numStartups": 3, "mcpServers": {"singularity": {"type": "stdio", "command": "\#(command)", "args": []}}}"#
    try json.write(to: AgentConnect.configFile(.claudeCode, home: home), atomically: true, encoding: .utf8)
}

private func writeCodexConfig(home: URL, command: String) throws {
    let file = AgentConnect.configFile(.codex, home: home)
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "[mcp_servers.singularity]\ncommand = \"\(command)\"\n".write(to: file, atomically: true, encoding: .utf8)
}

extension AppTests {
    @MainActor @Suite struct AgentConnectorTests {
        @Test func bothInstalledNoConfigFilesMeansNotConnected() async throws {
            _ = MainRunLoopGuard.start
            let shell = FakeShell()
            let connector = AgentConnector(launcher: launcher, home: try makeHome(), shell: shell)
            await connector.refresh()
            #expect(connector.rows[.claudeCode] == .status(.notConnected))
            #expect(connector.rows[.codex] == .status(.notConnected))
            let lines = await shell.lines
            #expect(Set(lines) == ["command -v claude", "command -v codex"])
        }

        @Test func claudeConfigNamingThisLauncherMeansConnected() async throws {
            _ = MainRunLoopGuard.start
            let home = try makeHome()
            try writeClaudeConfig(home: home, command: launcher)
            let connector = AgentConnector(launcher: launcher, home: home, shell: FakeShell())
            await connector.refresh()
            #expect(connector.rows[.claudeCode] == .status(.connected))
        }

        @Test func connectRunsTheAddCommandAndRereadsTheConfig() async throws {
            _ = MainRunLoopGuard.start
            let home = try makeHome()
            let add = AgentConnect.addCommand(.codex, launcher: launcher)
            let shell = FakeShell { line in
                if line == add { try? writeCodexConfig(home: home, command: launcher) }
                return (0, "", false)
            }
            let connector = AgentConnector(launcher: launcher, home: home, shell: shell)
            await connector.refresh()
            #expect(connector.rows[.codex] == .status(.notConnected))

            await connector.connect(.codex)
            #expect(connector.rows[.codex] == .status(.connected))
            #expect(await shell.lines.last == add)
            #expect(connector.command(for: .codex) == add)
        }

        @Test func updatingAnotherCopyRemovesThenAdds() async throws {
            _ = MainRunLoopGuard.start
            let home = try makeHome()
            let other = "/Users/someone/Singularity-Browser/build/Singularity.app/Contents/MacOS/singularity-mcp"
            try writeClaudeConfig(home: home, command: other)
            let add = AgentConnect.addCommand(.claudeCode, launcher: launcher)
            let remove = AgentConnect.removeCommand(.claudeCode)
            let shell = FakeShell { line in
                if line == add { try? writeClaudeConfig(home: home, command: launcher) }
                return (0, "", false)
            }
            let connector = AgentConnector(launcher: launcher, home: home, shell: shell)
            await connector.refresh()
            #expect(connector.rows[.claudeCode] == .status(.otherCopy(other)))

            await connector.connect(.claudeCode)
            let lines = await shell.lines.filter { !$0.hasPrefix("command -v") }
            #expect(lines == [remove, add])
            #expect(connector.rows[.claudeCode] == .status(.connected))
        }

        @Test func failingAddShowsTheProgramsOutput() async throws {
            _ = MainRunLoopGuard.start
            let shell = FakeShell { line in
                line.hasPrefix("command -v") ? (0, "", false) : (1, "boom\n", false)
            }
            let connector = AgentConnector(launcher: launcher, home: try makeHome(), shell: shell)
            await connector.refresh()
            await connector.connect(.claudeCode)
            #expect(connector.rows[.claudeCode] == .failed("boom"))
        }

        @Test func addThatLeavesTheFileUnchangedFails() async throws {
            _ = MainRunLoopGuard.start
            let connector = AgentConnector(launcher: launcher, home: try makeHome(), shell: FakeShell())
            await connector.refresh()
            await connector.connect(.codex)
            #expect(connector.rows[.codex] == .failed(
                "The agent did not keep the entry. If your shell sets CLAUDE_CONFIG_DIR or CODEX_HOME, use the command instead."))
        }

        /// Update said yes, but the file still names the other copy: that is an error, not a
        /// silent return to the Update button.
        @Test func updateThatLeavesTheOtherCopyFails() async throws {
            _ = MainRunLoopGuard.start
            let home = try makeHome()
            let other = "/Users/someone/Singularity-Browser/build/Singularity.app/Contents/MacOS/singularity-mcp"
            try writeClaudeConfig(home: home, command: other)
            let connector = AgentConnector(launcher: launcher, home: home, shell: FakeShell())
            await connector.refresh()
            #expect(connector.rows[.claudeCode] == .status(.otherCopy(other)))

            await connector.connect(.claudeCode)
            #expect(connector.rows[.claudeCode] == .failed("The entry still points at another copy."))
        }

        /// Connect runs only from a row that offers it ("not connected" or "another copy"): not
        /// while the check runs, and not on a row that is already connected.
        @Test func connectRunsNothingWhileCheckingOrWhenConnected() async throws {
            _ = MainRunLoopGuard.start
            let home = try makeHome()
            let shell = FakeShell()
            let connector = AgentConnector(launcher: launcher, home: home, shell: shell)
            #expect(connector.rows[.claudeCode] == .checking) // no check has run yet
            await connector.connect(.claudeCode)
            #expect(await shell.lines.isEmpty)
            #expect(connector.rows[.claudeCode] == .checking)

            try writeClaudeConfig(home: home, command: launcher)
            await connector.refresh()
            #expect(connector.rows[.claudeCode] == .status(.connected))
            let checked = await shell.lines
            await connector.connect(.claudeCode)
            #expect(await shell.lines == checked)
            #expect(connector.rows[.claudeCode] == .status(.connected))
        }

        @Test func timedOutLookupMeansNotInstalled() async throws {
            _ = MainRunLoopGuard.start
            let shell = FakeShell { _ in (-1, "", true) }
            let connector = AgentConnector(launcher: launcher, home: try makeHome(), shell: shell)
            await connector.refresh()
            #expect(connector.rows[.claudeCode] == .status(.notInstalled))
            #expect(connector.rows[.codex] == .status(.notInstalled))
        }

        @Test func translocatedLauncherNeverRunsACommand() async throws {
            _ = MainRunLoopGuard.start
            let shell = FakeShell()
            let translocated = "/private/var/folders/ab/xyz/T/AppTranslocation/1234-5678/d/Singularity.app/Contents/MacOS/singularity-mcp"
            let connector = AgentConnector(launcher: translocated, home: try makeHome(), shell: shell)
            await connector.refresh()
            #expect(connector.rows[.claudeCode] == .status(.translocated))
            #expect(connector.rows[.codex] == .status(.translocated))

            await connector.connect(.claudeCode)
            await connector.connect(.codex)
            #expect(await shell.lines.isEmpty)
            #expect(connector.rows[.claudeCode] == .status(.translocated))
        }

        /// Both Copy buttons (an agent row's command, step 4's prompt) go through `CopyText.copy`,
        /// which replaces what is on the pasteboard. A private named pasteboard, never the user's.
        @Test func copyPutsTheTextOnThePasteboard() throws {
            _ = MainRunLoopGuard.start
            let pasteboard = NSPasteboard(name: NSPasteboard.Name("dev.roosa.singularity.tests.\(UUID().uuidString)"))
            defer { pasteboard.releaseGlobally() }
            pasteboard.clearContents()
            pasteboard.setString("<b>old</b>", forType: .html)

            let connector = AgentConnector(launcher: launcher, home: try makeHome(), shell: FakeShell())
            let command = connector.command(for: .claudeCode)
            CopyText.copy(command, to: pasteboard)
            #expect(pasteboard.string(forType: .string) == command)
            #expect(pasteboard.string(forType: .html) == nil) // the old contents are gone

            let prompt = BundledPlugins.authoringPrompt(guide: URL(filePath: "/Applications/Singularity.app/Contents/Resources/plugin-guide"),
                                                        pluginsDirectory: URL(filePath: "/tmp/plugins"))
            CopyText.copy(prompt, to: pasteboard)
            #expect(pasteboard.string(forType: .string) == prompt)
            #expect(pasteboard.pasteboardItems?.count == 1)
        }
    }
}
