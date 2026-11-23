import Foundation

/// Which terminals have a coding agent running in front, and the per-Space numbers for the rail.
/// Pure: the app hands in the program names and states it already knows. Nothing is saved.
public enum RunningAgents {
    /// One running agent: a terminal tab, its Space and what the board says it is doing.
    public struct Row: Equatable, Sendable, Identifiable {
        public var tabID: UUID
        public var spaceID: UUID
        public var state: TerminalBoard.State
        public var id: UUID { tabID }

        public init(tabID: UUID, spaceID: UUID, state: TerminalBoard.State) {
            self.tabID = tabID
            self.spaceID = spaceID
            self.state = state
        }
    }

    public struct SpaceCount: Equatable, Sendable {
        public var count: Int
        public var anyWorking: Bool

        public init(count: Int, anyWorking: Bool) {
            self.count = count
            self.anyWorking = anyWorking
        }
    }

    /// Runners that start another program by name, and wrappers that only prefix a command.
    /// A launcher `npx @google/gemini-cli` must name `gemini-cli`, not `npx`: otherwise every
    /// `npx vite` dev server in any terminal would count as a running agent.
    private static let wrapperWords: Set<String> = [
        "npx", "bunx", "pnpx", "uvx", "pipx", "env", "sudo", "nice", "nohup", "time", "exec",
        "command", "caffeinate",
    ]
    /// The runners among them that take a package: their `-…` options and `run` are skipped too.
    private static let packageRunners: Set<String> = ["npx", "bunx", "pnpx", "uvx", "pipx"]

    /// The program names that count as agents: claude and codex always, plus the program each
    /// launcher command starts. Only the part after the last `&&`, `||` or `;` counts (so
    /// `cd ~/x && claude` gives `claude`); `NAME=value` assignments and the runner/wrapper
    /// words above are skipped, because they are generic and would match unrelated programs.
    public static func agentNames(launcherCommands: [String]) -> Set<String> {
        var names: Set<String> = ["claude", "codex"]
        for command in launcherCommands {
            var tail = Substring(command)
            for separator in ["&&", "||", ";"] {
                while let range = tail.range(of: separator) { tail = tail[range.upperBound...] }
            }
            var skippingRunnerOptions = false
            var found: String?
            for word in tail.split(whereSeparator: { $0.isWhitespace }).map(String.init) {
                if isAssignment(word) { continue }
                let lowered = word.lowercased()
                if wrapperWords.contains(lowered) {
                    skippingRunnerOptions = packageRunners.contains(lowered)
                    continue
                }
                if skippingRunnerOptions && (word.hasPrefix("-") || lowered == "run") { continue }
                found = word
                break
            }
            guard let found else { continue }
            let name = (found as NSString).lastPathComponent.lowercased()
            if !name.isEmpty { names.insert(name) }
        }
        return names
    }

    /// `program` is the process in front of the terminal (nil = the shell). Scripts show up with
    /// their extension (`codex.js`), so the name counts with and without it.
    public static func isAgent(program: String?, names: Set<String>) -> Bool {
        guard let program, !program.isEmpty else { return false }
        let lowered = program.lowercased()
        if names.contains(lowered) { return true }
        return names.contains((lowered as NSString).deletingPathExtension)
    }

    /// Spaces in the given order; within a Space, terminals in sidebar order. A tab with no
    /// state yet is `.unknown`.
    public static func rows(spaces: [Space], names: Set<String>,
                            program: (UUID) -> String?,
                            state: (UUID) -> TerminalBoard.State?) -> [Row] {
        var result: [Row] = []
        for space in spaces {
            for tab in space.tabsInSidebarOrder where tab.isTerminal {
                guard isAgent(program: program(tab.id), names: names) else { continue }
                result.append(Row(tabID: tab.id, spaceID: space.id, state: state(tab.id) ?? .unknown))
            }
        }
        return result
    }

    /// Per Space; a Space with no rows is absent.
    public static func counts(_ rows: [Row]) -> [UUID: SpaceCount] {
        var result: [UUID: SpaceCount] = [:]
        for row in rows {
            var entry = result[row.spaceID] ?? SpaceCount(count: 0, anyWorking: false)
            entry.count += 1
            if row.state == .working { entry.anyWorking = true }
            result[row.spaceID] = entry
        }
        return result
    }

    /// `FOO=1` at the start of a command: an environment assignment, not the program.
    private static func isAssignment(_ word: String) -> Bool {
        word.range(of: "^[A-Za-z_][A-Za-z0-9_]*=", options: .regularExpression) != nil
    }
}
