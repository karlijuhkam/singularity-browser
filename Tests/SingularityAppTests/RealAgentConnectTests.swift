import Foundation
import SingularityCore
import Testing
@testable import Singularity

/// Opt-in, never part of `scripts/test.sh`: Connect and Update with the REAL `claude` and `codex`,
/// run through the real login shell (`AgentLoginShell`), against throwaway config folders.
///
///     source scripts/env.sh && SINGULARITY_REAL_AGENTS=1 CLAUDE_CONFIG_DIR=/private/tmp/sg-agents-1 \
///     CODEX_HOME=/private/tmp/sg-agents-1/.codex swift test --filter RealAgentConnectTests
///
/// The two variables pass through the login shell to the agents, so `claude mcp add -s user`
/// writes `$CLAUDE_CONFIG_DIR/.claude.json` and `codex mcp add` writes `$CODEX_HOME/config.toml`:
/// exactly the files `AgentConnect.configFile(_:home:)` reads with home = `CLAUDE_CONFIG_DIR`.
/// Before anything runs, each test checks (`throwawayHome`) that both variables name such a folder,
/// both in this process and as the login shell sees them (the user's shell files could change
/// them), so the real `~/.claude.json` and `~/.codex/config.toml` are never touched. The launcher
/// paths don't exist, so nothing an agent might try to start can reach a copy of the app.
private let realAgentsRequested = ProcessInfo.processInfo.environment["SINGULARITY_REAL_AGENTS"] == "1"

extension AppTests {
    @MainActor
    @Suite(.serialized, .enabled(if: realAgentsRequested, "opt-in: set SINGULARITY_REAL_AGENTS=1, CLAUDE_CONFIG_DIR and CODEX_HOME"))
    struct RealAgentConnectTests {
        /// Left in the folder by the first test, so later tests know the folder is the suite's own.
        private static let marker = ".singularity-real-agents-test"

        /// The throwaway home (`CLAUDE_CONFIG_DIR`) with no agent config in it and an empty
        /// `.codex` folder. Nil, with an issue recorded, unless:
        /// - `CLAUDE_CONFIG_DIR` is exactly `/private/tmp/sg-agents-<letters, digits, - or _>` and
        ///   `CODEX_HOME` is exactly its `/.codex`;
        /// - the folder doesn't exist yet, or holds this suite's marker (it is never removed, and
        ///   nothing in a folder this suite didn't make is touched);
        /// - the login shell the connector uses reports the same two paths.
        /// Only the files the agents write for the test (`.claude.json`, `.codex/`) are removed.
        private func throwawayHome() async -> URL? {
            let environment = ProcessInfo.processInfo.environment
            guard let claude = environment["CLAUDE_CONFIG_DIR"], let codex = environment["CODEX_HOME"] else {
                Issue.record("CLAUDE_CONFIG_DIR and CODEX_HOME must both be set: refusing to run against the real config")
                return nil
            }
            let prefix = "/private/tmp/sg-agents-"
            let name = claude.hasPrefix(prefix) ? String(claude.dropFirst(prefix.count)) : ""
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
            guard !name.isEmpty, name.unicodeScalars.allSatisfy({ allowed.contains($0) }), codex == claude + "/.codex" else {
                Issue.record("CLAUDE_CONFIG_DIR must be /private/tmp/sg-agents-<name> and CODEX_HOME exactly its /.codex (got \(claude) and \(codex)): refusing to run")
                return nil
            }

            let home = URL(filePath: claude, directoryHint: .isDirectory)
            let files = FileManager.default
            let marker = home.appending(path: Self.marker)
            if files.fileExists(atPath: home.path) {
                guard files.fileExists(atPath: marker.path) else {
                    Issue.record("\(claude) exists and was not made by this suite: refusing to touch it. Use a new folder name.")
                    return nil
                }
            } else {
                do {
                    try files.createDirectory(at: home, withIntermediateDirectories: false)
                    try Data().write(to: marker)
                } catch {
                    Issue.record("could not create \(claude): \(error)")
                    return nil
                }
            }

            // The login shell must hand the agents the same two folders: it runs the user's shell
            // files, which could change or unset them, and then `mcp add/remove` would hit the
            // real config. The markers keep shell start-up messages out of the comparison.
            let seen = await AgentLoginShell().run(#"printf '<<%s|%s>>' "$CLAUDE_CONFIG_DIR" "$CODEX_HOME""#)
            let expected = "\(claude)|\(codex)"
            // Every "<<…>>" in the output; exactly one is wanted, and it must be the expected one.
            let reported = seen.output.components(separatedBy: "<<").dropFirst()
                .map { $0.components(separatedBy: ">>").first ?? "" }
            guard seen.exitCode == 0, !seen.timedOut, reported == [expected] else {
                Issue.record("the login shell reports \(reported) (exit \(seen.exitCode)), not \(expected): refusing to run")
                return nil
            }

            // Only what the agents write for these tests.
            try? files.removeItem(at: AgentConnect.configFile(.claudeCode, home: home))
            try? files.removeItem(at: home.appending(path: ".codex"))
            do {
                try files.createDirectory(at: home.appending(path: ".codex"), withIntermediateDirectories: false)
            } catch {
                Issue.record("could not create \(codex): \(error)")
                return nil
            }
            return home
        }

        /// A launcher path inside the throwaway home (not a real file).
        private func launcher(in home: URL, app: String = "Singularity.app") -> String {
            home.appending(path: app).appending(path: "Contents/MacOS/singularity-mcp").path
        }

        /// What the agent's own config file (in the throwaway home) says "singularity" points at.
        private func registered(_ agent: AgentKind, home: URL) -> String? {
            let file = AgentConnect.configFile(agent, home: home)
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
            return AgentConnect.registeredLauncher(agent, configText: text)
        }

        /// For the report: the entry as the agent wrote it.
        private func show(_ agent: AgentKind, home: URL) {
            let file = AgentConnect.configFile(agent, home: home)
            let text = (try? String(contentsOf: file, encoding: .utf8)) ?? "(missing)"
            switch agent {
            case .claudeCode:
                let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
                let servers = object?["mcpServers"] ?? "(none)"
                print("real-agents: \(file.path) mcpServers = \(servers)")
            case .codex:
                print("real-agents: \(file.path):\n\(text)")
            }
        }

        @Test func bothAgentsAreFoundAndNotConnected() async throws {
            _ = MainRunLoopGuard.start
            guard let home = await throwawayHome() else { return }
            let connector = AgentConnector(launcher: launcher(in: home), home: home, shell: AgentLoginShell(), separateDataFolder: false)
            await connector.refresh()
            #expect(connector.rows[.claudeCode] == .status(.notConnected))
            #expect(connector.rows[.codex] == .status(.notConnected))
        }

        @Test(arguments: [AgentKind.claudeCode, .codex])
        func connectWritesTheEntryTheCheckReads(agent: AgentKind) async throws {
            _ = MainRunLoopGuard.start
            guard let home = await throwawayHome() else { return }
            let path = launcher(in: home)
            let connector = AgentConnector(launcher: path, home: home, shell: AgentLoginShell(), separateDataFolder: false)
            await connector.refresh()
            #expect(connector.rows[agent] == .status(.notConnected))

            await connector.connect(agent)
            show(agent, home: home)
            #expect(connector.rows[agent] == .status(.connected))
            #expect(registered(agent, home: home) == path)
            if agent == .claudeCode {
                // The exact shape: top-level mcpServers.singularity.command.
                let data = try Data(contentsOf: AgentConnect.configFile(.claudeCode, home: home))
                let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
                let entry = (root["mcpServers"] as? [String: Any])?["singularity"] as? [String: Any]
                #expect(entry?["command"] as? String == path)
            }
            // The other agent was left alone.
            let other: AgentKind = agent == .claudeCode ? .codex : .claudeCode
            #expect(registered(other, home: home) == nil)
        }

        @Test(arguments: [AgentKind.claudeCode, .codex])
        func updateReplacesAnEntryForAnotherCopy(agent: AgentKind) async throws {
            _ = MainRunLoopGuard.start
            guard let home = await throwawayHome() else { return }
            let other = launcher(in: home, app: "Other.app")
            switch agent {
            case .claudeCode:
                let json = #"{"mcpServers": {"singularity": {"type": "stdio", "command": "\#(other)", "args": [], "env": {}}}}"#
                try json.write(to: AgentConnect.configFile(.claudeCode, home: home), atomically: true, encoding: .utf8)
            case .codex:
                try "[mcp_servers.singularity]\ncommand = \"\(other)\"\n"
                    .write(to: AgentConnect.configFile(.codex, home: home), atomically: true, encoding: .utf8)
            }
            let path = launcher(in: home)
            let connector = AgentConnector(launcher: path, home: home, shell: AgentLoginShell(), separateDataFolder: false)
            await connector.refresh()
            #expect(connector.rows[agent] == .status(.otherCopy(other)))

            await connector.connect(agent) // Update: remove, then add
            show(agent, home: home)
            #expect(connector.rows[agent] == .status(.connected))
            #expect(registered(agent, home: home) == path)
        }

        @Test(arguments: [AgentKind.claudeCode, .codex])
        func aPathWithASpaceAndAQuoteRoundTrips(agent: AgentKind) async throws {
            _ = MainRunLoopGuard.start
            guard let home = await throwawayHome() else { return }
            let path = launcher(in: home, app: "Test's Copy.app")
            #expect(path.contains(" ") && path.contains("'"))
            let connector = AgentConnector(launcher: path, home: home, shell: AgentLoginShell(), separateDataFolder: false)
            await connector.refresh()
            await connector.connect(agent)
            show(agent, home: home)
            #expect(connector.rows[agent] == .status(.connected))
            #expect(registered(agent, home: home) == path)
        }
    }
}
