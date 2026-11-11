import Foundation
import Observation
import SingularityCore

/// Runs one command line the way a terminal tab would see it. Tests pass a fake.
protocol AgentShell: Sendable {
    func run(_ commandLine: String) async -> (exitCode: Int32, output: String, timedOut: Bool)
}

/// The user's login shell: `$SHELL -l -i -c <commandLine>`, cwd = home, stdin = /dev/null, 20 s timeout.
/// (Not called `LoginShell`: that name is Core's helper for finding the shell, used by terminal tabs.)
///
/// Why a login + interactive shell: an app started from the Dock gets a minimal PATH, while the
/// agents usually live in places only the user's shell setup knows (`~/.nvm/…/bin` for codex, which
/// also needs `node` on the PATH), and `claude` may even be a shell function in `.zshrc`. `-l` reads
/// the login files (.zprofile), `-i` the interactive ones (.zshrc), just like a terminal tab.
/// Without a terminal attached, the shell may print warnings (e.g. about line editing); callers use
/// the exit code to decide and show the output only when something failed.
struct AgentLoginShell: AgentShell {
    func run(_ commandLine: String) async -> (exitCode: Int32, output: String, timedOut: Bool) {
        let result = await CommandBroker.run(
            path: Self.shellPath,
            arguments: ["-l", "-i", "-c", commandLine],
            timeout: .seconds(20),
            currentDirectory: FileManager.default.homeDirectoryForCurrentUser
        )
        // One text for the user: what the program printed, normal output first, then errors.
        let output = [result.stdout, result.stderr].filter { !$0.isEmpty }.joined(separator: "\n")
        return (result.status, output, result.timedOut)
    }

    /// `$SHELL`, else the shell in the user's account record (`getpwuid`), else zsh. The last two
    /// steps are Core's `LoginShell.path()`, the same lookup terminal tabs use.
    static var shellPath: String {
        if let shell = ProcessInfo.processInfo.environment["SHELL"], !shell.isEmpty { return shell }
        return LoginShell.path()
    }
}

/// The state behind the Connect rows (Settings → Agents, and the welcome flow): for each agent,
/// whether it is installed and where its "singularity" entry points, and the Connect/Update action.
/// The check only reads the agents' config files (never `claude mcp get`, which would start the
/// registered launcher); changes always go through the agents' own `mcp add/remove` commands.
@MainActor @Observable final class AgentConnector {
    enum RowState: Equatable {
        case checking
        case status(AgentConnectStatus)
        case working                     // Connect/Update running
        case failed(String)              // the program's error text, trimmed, max 300 characters
    }

    private(set) var rows: [AgentKind: RowState]
    let launcher: String
    private let home: URL
    private let shell: AgentShell

    /// The launcher inside *this* copy of the app (what agents should be pointed at).
    static var thisAppLauncher: String {
        Bundle.main.bundleURL.appending(path: "Contents/MacOS/singularity-mcp").path
    }

    init(launcher: String, home: URL = FileManager.default.homeDirectoryForCurrentUser, shell: AgentShell = AgentLoginShell()) {
        self.launcher = launcher
        self.home = home
        self.shell = shell
        rows = Dictionary(uniqueKeysWithValues: AgentKind.allCases.map { ($0, RowState.checking) })
    }

    /// The command a user can copy and run in a terminal themselves.
    func command(for agent: AgentKind) -> String {
        AgentConnect.addCommand(agent, launcher: launcher)
    }

    /// Checks both agents at the same time. A row whose Connect is still running is left alone.
    func refresh() async {
        await withTaskGroup(of: Void.self) { group in
            for agent in AgentKind.allCases where rows[agent] != .working {
                rows[agent] = .checking
                group.addTask { await self.refreshRow(agent) }
            }
        }
    }

    /// Connect (add), or Update for an entry pointing at another copy (remove, then add). Then reads
    /// the config again and shows what it says. Does nothing for a translocated app.
    func connect(_ agent: AgentKind) async {
        guard !AgentConnect.isTranslocated(launcher), rows[agent] != .working else { return }
        var lines = [AgentConnect.addCommand(agent, launcher: launcher)]
        if case .status(.otherCopy) = rows[agent] {
            lines.insert(AgentConnect.removeCommand(agent), at: 0)
        }
        rows[agent] = .working

        for line in lines {
            let result = await shell.run(line)
            if result.exitCode != 0 || result.timedOut {
                rows[agent] = .failed(Self.failureText(result))
                return
            }
        }

        // The agent said yes; believe its config file, not its exit code.
        let registered = await Self.registeredLauncher(agent, home: home)
        let status = AgentConnect.status(installed: true, registered: registered, launcher: launcher)
        rows[agent] = status == .notConnected ? .failed("The agent did not keep the entry.") : .status(status)
    }

    // MARK: - Private

    private func refreshRow(_ agent: AgentKind) async {
        // A translocated app has nothing to offer (no button, no command): don't run anything.
        if AgentConnect.isTranslocated(launcher) {
            rows[agent] = .status(.translocated)
            return
        }
        async let registered = Self.registeredLauncher(agent, home: home)
        // Only the exit code counts: the shell may print warnings even when the program is there.
        let found = await shell.run(AgentConnect.findCommand(agent))
        let installed = found.exitCode == 0 && !found.timedOut
        rows[agent] = .status(AgentConnect.status(installed: installed, registered: await registered, launcher: launcher))
    }

    /// Where the agent's config file says "singularity" points; nil when the file is missing,
    /// unreadable or has no such entry. `nonisolated` so the read (~/.claude.json can be large)
    /// happens off the main thread.
    private nonisolated static func registeredLauncher(_ agent: AgentKind, home: URL) async -> String? {
        let file = AgentConnect.configFile(agent, home: home)
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        return AgentConnect.registeredLauncher(agent, configText: text)
    }

    /// The program's own words, trimmed; the end is kept when it is long, since that is where the
    /// error usually is (a login shell may print its own warnings first).
    private static func failureText(_ result: (exitCode: Int32, output: String, timedOut: Bool)) -> String {
        let text = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            return result.timedOut ? "It took too long and was stopped." : "It stopped with exit code \(result.exitCode)."
        }
        return text.count <= 300 ? text : "…" + text.suffix(299)
    }
}
