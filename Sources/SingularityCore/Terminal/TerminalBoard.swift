import Foundation

/// The latest known state of each terminal tab, built from the same signals the inbox reads.
/// Pure: the app feeds it signals and asks for rows. Nothing is saved.
public struct TerminalBoard: Sendable {
    public enum State: String, Sendable { case working, waiting, done, idle, unknown }

    public struct Row: Equatable, Sendable {
        public var state: State
        public var reason: InboxWaitingReason?   // only when waiting
        public var message: String?              // cleaned with InboxText.clean, cut at 1000
        public var since: Date

        public init(state: State, reason: InboxWaitingReason? = nil, message: String? = nil, since: Date) {
            self.state = state
            self.reason = reason
            self.message = message
            self.since = since
        }
    }

    private var rows: [UUID: Row] = [:]
    /// Tabs that have ever sent a status record: their bells and notifications are ignored
    /// (the same trust rule as the inbox's level 1).
    private var reportsStatus: Set<UUID> = []

    public init() {}

    /// `foregroundProgram` nil = the shell is in front.
    public mutating func apply(_ signal: TerminalSignal, tabID: UUID, foregroundProgram: String?, now: Date) {
        switch signal {
        case .status(let records):
            if !records.isEmpty { reportsStatus.insert(tabID) }
            guard let record = InboxRules.summarise(records) else {
                set(tabID, state: .idle, reason: nil, message: nil, now: now)
                return
            }
            let message = record.message.map { InboxText.clean($0, limit: 1000) }
            switch record.state {
            case .blocked: set(tabID, state: .waiting, reason: record.kind ?? .attention, message: message, now: now)
            case .error: set(tabID, state: .waiting, reason: .error, message: message, now: now)
            case .working: set(tabID, state: .working, reason: nil, message: nil, now: now)
            case .done: set(tabID, state: .done, reason: nil, message: message, now: now)
            case .idle: set(tabID, state: .idle, reason: nil, message: nil, now: now)
            }
        case .notification(_, let body):
            guard !reportsStatus.contains(tabID) else { return }
            set(tabID, state: .waiting, reason: .attention, message: InboxText.clean(body, limit: 1000), now: now)
        case .bell:
            guard !reportsStatus.contains(tabID), foregroundProgram != nil else { return }
            set(tabID, state: .waiting, reason: .attention, message: nil, now: now)
        case .programExited:
            set(tabID, state: .idle, reason: nil, message: nil, now: now)
        }
    }

    /// nil = nothing was ever reported for this tab (unknown).
    public func row(_ tabID: UUID) -> Row? { rows[tabID] }

    public mutating func remove(_ tabID: UUID) {
        rows[tabID] = nil
        reportsStatus.remove(tabID)
    }

    /// `since` moves only when the state or the reason changes; the message may update in place.
    private mutating func set(_ tabID: UUID, state: State, reason: InboxWaitingReason?, message: String?, now: Date) {
        var since = now
        if let old = rows[tabID], old.state == state, old.reason == reason { since = old.since }
        rows[tabID] = Row(state: state, reason: reason, message: message, since: since)
    }
}
