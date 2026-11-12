import Foundation

public enum ProgramState: String, Sendable { case idle, working, done, blocked, error }

/// One status record a program reports for its terminal tab.
public struct StatusRecord: Equatable, Sendable {
    public var id: String
    public var state: ProgramState
    public var kind: InboxWaitingReason?  // question / permission / auth when blocked
    public var app: String?
    public var message: String?

    public init(id: String, state: ProgramState, kind: InboxWaitingReason?, app: String?, message: String?) {
        self.id = id
        self.state = state
        self.kind = kind
        self.app = app
        self.message = message
    }
}

public enum TerminalSignal: Equatable, Sendable {
    case status([StatusRecord])           // all current records of the tab; [] = none left
    case notification(title: String, body: String)
    case bell
    case programExited                    // foreground went back to the shell, or the shell ended
}

public struct TabFacts: Equatable, Sendable {
    public var tabID: UUID
    public var spaceID: UUID
    public var foregroundProgram: String? // nil = shell at its prompt
    public var isLookedAt: Bool

    public init(tabID: UUID, spaceID: UUID, foregroundProgram: String?, isLookedAt: Bool) {
        self.tabID = tabID
        self.spaceID = spaceID
        self.foregroundProgram = foregroundProgram
        self.isLookedAt = isLookedAt
    }
}

public enum InboxRules {
    /// One record speaks for the tab: the most urgent state wins
    /// (blocked > error > done > working > idle); ties go to the record with the shorter id.
    public static func summarise(_ records: [StatusRecord]) -> StatusRecord? {
        func rank(_ s: ProgramState) -> Int {
            switch s {
            case .blocked: 4
            case .error: 3
            case .done: 2
            case .working: 1
            case .idle: 0
            }
        }
        return records.min { a, b in
            if rank(a.state) != rank(b.state) { return rank(a.state) > rank(b.state) }
            return a.id.count < b.id.count
        }
    }

    /// claude → "Claude Code", codex → "Codex", hermes → "Hermes" (case-insensitive, matched on
    /// the status record's app first, then the foreground program); else the program name; else "Agent".
    public static func agentName(statusApp: String?, foregroundProgram: String?) -> String {
        for candidate in [statusApp, foregroundProgram] {
            if let name = known(candidate) { return name }
        }
        if let program = foregroundProgram, !program.isEmpty { return program }
        return "Agent"
    }

    /// "Looked at" = the user can see the tab right now: all three must hold.
    public static func isLookedAt(appIsActive: Bool, windowIsKey: Bool, tabIsOnScreen: Bool) -> Bool {
        appIsActive && windowIsKey && tabIsOnScreen
    }

    /// Matches by prefix, so `claude`, `claude-code` and `Claude Code` all map to "Claude Code".
    private static func known(_ raw: String?) -> String? {
        guard let lower = raw?.lowercased() else { return nil }
        if lower.hasPrefix("claude") { return "Claude Code" }
        if lower.hasPrefix("codex") { return "Codex" }
        if lower.hasPrefix("hermes") { return "Hermes" }
        return nil
    }
}
