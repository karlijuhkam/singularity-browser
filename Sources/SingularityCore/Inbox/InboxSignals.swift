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

extension StatusRecord {
    /// A status record as SwiftTerm hands it over (OSC 7501), with its enums spelled as strings.
    /// SwiftTerm has already decoded the base64 `msg`. Nil for a state we don't know; an unknown
    /// `kind` is dropped (the entry then just says "waiting"). `kind` only counts when blocked.
    public init?(terminalID id: String, state: String, kind: String?, app: String?, message: String?) {
        guard let programState = ProgramState(rawValue: state) else { return nil }
        let reason = programState == .blocked ? kind.flatMap(InboxWaitingReason.init(rawValue:)) : nil
        self.init(id: id, state: programState, kind: reason, app: app, message: message)
    }
}

/// Terminal notifications, from the raw bytes of an OSC sequence (what follows `ESC ] <code> ;`).
public enum TerminalNotificationPayload {
    /// - OSC 777: `notify;<title>;<body>` (the body may contain `;`). Anything else is ignored.
    /// - OSC 9: the payload is the text. A payload that starts with a number and `;` is a
    ///   numbered sub-command, not a notification (`4;…` progress report, ConEmu's `9;<cwd>`,
    ///   which some prompt themes send at every prompt), and so is one of only digits and
    ///   semicolons: all ignored.
    /// Nil for other codes and for bytes that aren't UTF-8. The text is not cleaned here: the
    /// inbox cleans everything it keeps.
    public static func signal(code: Int, payload: [UInt8]) -> TerminalSignal? {
        guard code == 777 || code == 9, let text = String(bytes: payload, encoding: .utf8) else { return nil }
        if code == 777 {
            let parts = text.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 3, parts[0] == "notify" else { return nil }
            return .notification(title: parts[1], body: parts[2...].joined(separator: ";"))
        }
        if isSubCommand(text) || text.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ";") }) { return nil }
        return .notification(title: "", body: text)
    }

    /// One or more ASCII digits, then `;`.
    private static func isSubCommand(_ text: String) -> Bool {
        let digits = text.prefix { $0.isASCII && $0.isNumber }
        return !digits.isEmpty && text.dropFirst(digits.count).first == ";"
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
    /// (blocked > error > working > done > idle); ties go to the record with the shorter id.
    /// Working outranks done because a program may keep several records: Claude Code has records
    /// for its subagents and tasks, and one that finished while the main turn goes on must not
    /// make the tab look done (a false done card and banner, held requests released, and no
    /// banner at the real end). The cost: a tab whose child record keeps saying `working` after
    /// the turn ended stays "working" until that record goes.
    public static func summarise(_ records: [StatusRecord]) -> StatusRecord? {
        func rank(_ s: ProgramState) -> Int {
            switch s {
            case .blocked: 4
            case .error: 3
            case .working: 2
            case .done: 1
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

/// What a macOS notification for an inbox entry says. Everything in an entry came from an agent
/// or a page, so the title parts and the body are cleaned here, not by the caller.
public enum InboxNotificationText {
    static let titlePartLimit = 80

    /// Title "<agent> · <Space name>" (just the agent when there is no Space name). Body by kind:
    /// question → the first question; permission → "Wants to use <tool>"; approval → "Wants to
    /// <action>"; waiting → the message or "Waiting for you"; done → the message or "Finished".
    public static func make(_ entry: InboxEntry, spaceName: String) -> (title: String, body: String) {
        let agent = InboxText.clean(entry.agent, limit: titlePartLimit)
        let space = InboxText.clean(spaceName, limit: titlePartLimit)
        let title = space.isEmpty ? agent : "\(agent) · \(space)"

        let raw: String
        switch entry.kind {
        case .question(let questions): raw = questions.first?.question ?? ""
        case .permission(let tool, _): raw = "Wants to use \(tool)"
        case .approval(let approval): raw = "Wants to \(approval.action)"
        case .waiting: raw = entry.message ?? "Waiting for you"
        case .done: raw = entry.message ?? "Finished"
        }
        var body = InboxText.clean(raw, limit: InboxText.notificationLimit)
        if body.isEmpty { body = entry.isHeld ? "Waiting for you" : "Finished" }
        return (title, body)
    }
}
