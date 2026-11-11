import Foundation
import SingularityCore
import Testing
@testable import Singularity

/// Opt-in, never part of `scripts/test.sh`: Connect and Update with the REAL `claude` and `codex`,
/// run through the real login shell (`AgentLoginShell`), against throwaway config folders.
///
///     SINGULARITY_REAL_AGENTS=1 CLAUDE_CONFIG_DIR=/private/tmp/sg-agents \
///     CODEX_HOME=/private/tmp/sg-agents/.codex swift test --filter RealAgentConnectTests
///
/// The two variables pass through the login shell to the agents, so `claude mcp add -s user`
/// writes `$CLAUDE_CONFIG_DIR/.claude.json` and `codex mcp add` writes `$CODEX_HOME/config.toml`:
/// exactly the files `AgentConnect.configFile(_:home:)` reads with home = `CLAUDE_CONFIG_DIR`.
/// Each test refuses to run unless both point inside /private/tmp that way, so the real
/// `~/.claude.json` and `~/.codex/config.toml` are never touched. The launcher paths don't exist,
/// so nothing an agent might try to start can reach a copy of the app.
private let realAgentsRequested = ProcessInfo.processInfo.environment["SINGULARITY_REAL_AGENTS"] == "1"

extension AppTests {
    @MainActor
    @Suite(.serialized, .enabled(if: realAgentsRequested, "opt-in: set SINGULARITY_REAL_AGENTS=1, CLAUDE_CONFIG_DIR and CODEX_HOME"))
    struct RealAgentConnectTests {
        /// The throwaway home (`CLAUDE_CONFIG_DIR`), emptied, with an empty `.codex` folder in it.
        /// Nil, with an issue recorded, unless `CLAUDE_CONFIG_DIR` is a folder inside /private/tmp
        /// and `CODEX_HOME` is its `.codex`.
        private func throwawayHome() -> URL? {
            let environment = ProcessInfo.processInfo.environment
            guard let claude = environment["CLAUDE_CONFIG_DIR"], let codex = environment["CODEX_HOME"] else {
                Issue.record("CLAUDE_CONFIG_DIR and CODEX_HOME must both be set: refusing to run against the real config")
                return nil
            }
            let home: String = claude.hasSuffix("/") ? String(claude.dropLast()) : claude
            let components: [String] = home.split(separator: "/").map(String.init)
            let codexHome: String = home + "/.codex"
            guard home.hasPrefix("/private/tmp/"), components.count >= 3, !components.contains(".."),
                  codex == codexHome || codex == codexHome + "/" else {
                Issue.record("CLAUDE_CONFIG_DIR must be a folder inside /private/tmp and CODEX_HOME its .codex (got \(claude) and \(codex)): refusing to run")
                return nil
            }
            let url = URL(filePath: home, directoryHint: .isDirectory)
            try? FileManager.default.removeItem(at: url)
            do {
                try FileManager.default.createDirectory(at: url.appending(path: ".codex"), withIntermediateDirectories: true)
            } catch {
                Issue.record("could not create \(home): \(error)")
                return nil
            }
            return url
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
            guard let home = throwawayHome() else { return }
            let connector = AgentConnector(launcher: launcher(in: home), home: home, shell: AgentLoginShell())
            await connector.refresh()
            #expect(connector.rows[.claudeCode] == .status(.notConnected))
            #expect(connector.rows[.codex] == .status(.notConnected))
        }

        @Test(arguments: [AgentKind.claudeCode, .codex])
        func connectWritesTheEntryTheCheckReads(agent: AgentKind) async throws {
            _ = MainRunLoopGuard.start
            guard let home = throwawayHome() else { return }
            let path = launcher(in: home)
            let connector = AgentConnector(launcher: path, home: home, shell: AgentLoginShell())
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
            guard let home = throwawayHome() else { return }
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
            let connector = AgentConnector(launcher: path, home: home, shell: AgentLoginShell())
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
            guard let home = throwawayHome() else { return }
            let path = launcher(in: home, app: "Test's Copy.app")
            #expect(path.contains(" ") && path.contains("'"))
            let connector = AgentConnector(launcher: path, home: home, shell: AgentLoginShell())
            await connector.refresh()
            await connector.connect(agent)
            show(agent, home: home)
            #expect(connector.rows[agent] == .status(.connected))
            #expect(registered(agent, home: home) == path)
        }
    }
}
