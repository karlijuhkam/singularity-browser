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

    /// The program names that count as agents: claude and codex always, plus the program each
    /// launcher command starts (its first word that is not a `NAME=value` assignment).
    public static func agentNames(launcherCommands: [String]) -> Set<String> {
        var names: Set<String> = ["claude", "codex"]
        for command in launcherCommands {
            let words = command.split(whereSeparator: { $0.isWhitespace })
            guard let word = words.first(where: { !isAssignment(String($0)) }) else { continue }
            let name = (String(word) as NSString).lastPathComponent.lowercased()
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
