import Foundation

/// The inbox: a list of things waiting for the owner, and every rule about what a terminal signal,
/// a held hook request or a browser approval does to it. Pure value type; the app owns one.
///
/// Kinds of entry:
/// - level 1 (`.waiting`, `.done`): learned from the terminal (status records, bells, notifications).
///   At most one per tab.
/// - level 2 (`.question`, `.permission`): a Claude Code hook request the app is holding open
///   ("held"). Several per tab are possible. While a tab has one, its level-1 entry is hidden.
/// - `.approval`: a browser approval. Leaves by answer, timeout or tab close only.
public struct Inbox: Equatable, Sendable {
    public private(set) var entries: [InboxEntry] = []      // storage order = arrival
    public private(set) var workingTabs: Set<UUID> = []

    // Private bookkeeping.
    private var speaksStatus: Set<UUID> = []                // tabs that have sent a status record
    private var lastMessages: [UUID: String] = [:]          // Stop-hook texts (cleaned), by tab
    private var released: [InboxEntry] = []                 // held entries removed by apply/noteLastMessage

    public init() {}

    public enum Change: Equatable, Sendable {
        case none
        case added(InboxEntry)      // notify-worthy
        case changed                // list differs, nothing new to announce
    }

    // MARK: Reading

    /// Approvals, then held, then waiting, then done; oldest first in each group.
    public var ordered: [InboxEntry] {
        func rank(_ e: InboxEntry) -> Int {
            if case .approval = e.kind { return 0 }
            if e.isHeld { return 1 }
            if case .waiting = e.kind { return 2 }
            return 3
        }
        // The storage index breaks ties, so equal times keep arrival order.
        return entries.enumerated()
            .sorted { a, b in
                let (ra, rb) = (rank(a.element), rank(b.element))
                if ra != rb { return ra < rb }
                if a.element.arrived != b.element.arrived { return a.element.arrived < b.element.arrived }
                return a.offset < b.offset
            }
            .map(\.element)
    }

    /// `ordered` minus level-1 entries of tabs that have a held entry.
    public var visible: [InboxEntry] {
        let heldTabs = Set(entries.filter(\.isHeld).compactMap(\.tabID))
        return ordered.filter { entry in
            guard Inbox.isLevelOne(entry), let tabID = entry.tabID else { return true }
            return !heldTabs.contains(tabID)
        }
    }

    public var count: Int { visible.count }

    public func count(spaceID: UUID) -> Int { visible.filter { $0.spaceID == spaceID }.count }

    /// Working tabs that no visible entry already speaks for.
    public var workingCount: Int {
        workingTabs.subtracting(Set(visible.compactMap(\.tabID))).count
    }

    // MARK: Level 1

    public mutating func apply(_ signal: TerminalSignal, tab: TabFacts, agent: String, now: Date) -> Change {
        switch signal {
        case .status(let records):
            return applyStatus(records, tab: tab, agent: agent, now: now)

        case .notification(let title, let body):
            if speaksStatus.contains(tab.tabID) { return .none }
            // Entry messages share one limit; the shorter macOS notification body is the caller's job.
            let bodyText = InboxText.clean(body, limit: InboxText.messageLimit)
            let titleText = InboxText.clean(title, limit: InboxText.messageLimit)
            let message = !bodyText.isEmpty ? bodyText : (!titleText.isEmpty ? titleText : nil)
            return raise(.waiting(.attention), message: message, tab: tab, agent: agent, now: now)

        case .bell:
            if speaksStatus.contains(tab.tabID) || tab.foregroundProgram == nil { return .none }
            // A bell carries no text: a second one must not announce again or wipe a message.
            if let i = levelOneIndex(of: tab.tabID), entries[i].kind == .waiting(.attention) { return .none }
            return raise(.waiting(.attention), message: nil, tab: tab, agent: agent, now: now)

        case .programExited:
            let before = (entries, workingTabs)
            workingTabs.remove(tab.tabID)
            speaksStatus.remove(tab.tabID)
            lastMessages[tab.tabID] = nil
            removeLevelOne(of: tab.tabID)
            release(tab.tabID) { _ in true }
            return (entries, workingTabs) != before ? .changed : .none
        }
    }

    private mutating func applyStatus(_ records: [StatusRecord], tab: TabFacts, agent: String, now: Date) -> Change {
        let before = (entries, workingTabs)
        let id = tab.tabID
        if !records.isEmpty { speaksStatus.insert(id) }

        guard let summary = InboxRules.summarise(records), summary.state != .idle else {
            // Idle or no records: the agent is not doing anything any more.
            workingTabs.remove(id)
            removeLevelOne(of: id)
            release(id) { _ in true }
            return (entries, workingTabs) != before ? .changed : .none
        }

        let message = InboxText.clean(summary.message ?? "", limit: InboxText.messageLimit)
        switch summary.state {
        case .working:
            workingTabs.insert(id)
            lastMessages[id] = nil
            removeLevelOne(of: id)
            // The owner may have answered a permission dialog in the terminal without the held hook
            // being told, so release held permissions. A held question stays: the status is
            // `working` while a question hook is held.
            release(id) { if case .permission = $0.kind { true } else { false } }
            return (entries, workingTabs) != before ? .changed : .none

        case .done:
            workingTabs.remove(id)
            release(id) { _ in true }
            // The Stop hook's text is the real last message; the status text is a short summary.
            let text = lastMessages[id] ?? (message.isEmpty ? nil : message)
            return raise(.done, message: text, tab: tab, agent: agent, now: now)

        case .blocked, .error:
            workingTabs.remove(id)
            let kind: InboxKind = summary.state == .error ? .waiting(.error) : .waiting(summary.kind ?? .attention)
            return raise(kind, message: message.isEmpty ? nil : message, tab: tab, agent: agent, now: now)

        case .idle:
            return .none   // handled above
        }
    }

    /// Creates or updates the tab's level-1 entry.
    /// - Same state as the existing entry: updated in place (keeps `arrived`), `.changed`.
    /// - Tab looked at: no new entry; a stale entry in another state is dropped.
    private mutating func raise(_ kind: InboxKind, message: String?, tab: TabFacts, agent: String, now: Date) -> Change {
        let existing = levelOneIndex(of: tab.tabID)
        if let i = existing, entries[i].kind == kind {
            entries[i].message = message
            entries[i].agent = agent
            return .changed
        }
        if let i = existing { entries.remove(at: i) }
        if tab.isLookedAt { return existing == nil ? .none : .changed }
        let entry = InboxEntry(kind: kind, spaceID: tab.spaceID, tabID: tab.tabID, agent: agent,
                               message: message, arrived: now)
        entries.append(entry)
        return .added(entry)
    }

    /// The Stop hook: the agent's turn ended. Its text wins over the status record's short summary,
    /// whichever arrives first. Held requests of the tab can no longer be answered: released.
    public mutating func noteLastMessage(_ text: String, tabID: UUID) {
        let cleaned = InboxText.clean(text, limit: InboxText.messageLimit)
        lastMessages[tabID] = cleaned
        if let i = entries.firstIndex(where: { $0.tabID == tabID && $0.kind == .done }) {
            entries[i].message = cleaned.isEmpty ? nil : cleaned
        }
        release(tabID) { _ in true }
    }

    /// Held entries that `apply` / `noteLastMessage` removed since the last call. The caller replies
    /// "no decision" to each of them. Each is returned once.
    public mutating func takeReleased() -> [InboxEntry] {
        defer { released = [] }
        return released
    }

    // MARK: Level 2

    /// Returns nil (the caller replies "no decision") when the owner is looking at the tab.
    public mutating func hold(_ kind: InboxKind, tab: TabFacts, agent: String, now: Date) -> InboxEntry? {
        guard !tab.isLookedAt else { return nil }
        let entry = InboxEntry(kind: kind, spaceID: tab.spaceID, tabID: tab.tabID, agent: agent,
                               message: nil, arrived: now)
        entries.append(entry)
        return entry
    }

    /// Hold limit reached: the held entry becomes a level-1 waiting entry (same reason, same `arrived`).
    public mutating func demote(_ id: UUID) {
        guard let i = entries.firstIndex(where: { $0.id == id }), entries[i].isHeld,
              let tabID = entries[i].tabID else { return }
        let old = entries[i]
        let reason: InboxWaitingReason
        if case .question = old.kind { reason = .question } else { reason = .permission }
        let demoted = InboxEntry(kind: .waiting(reason), spaceID: old.spaceID, tabID: tabID,
                                 agent: old.agent, message: old.message, arrived: old.arrived)
        entries[i] = demoted
        // One level-1 entry per tab: an older one gives way.
        if let other = levelOneIndex(of: tabID, excluding: demoted.id) { entries.remove(at: other) }
    }

    // MARK: Approvals

    public mutating func addApproval(_ approval: InboxApproval, spaceID: UUID, tabID: UUID?,
                                     deadline: Date, now: Date) -> InboxEntry {
        let entry = InboxEntry(kind: .approval(approval), spaceID: spaceID, tabID: tabID,
                               agent: approval.actor, message: nil, arrived: now, deadline: deadline)
        entries.append(entry)
        return entry
    }

    public mutating func setDeadline(_ id: UUID, _ deadline: Date) {
        if let i = entries.firstIndex(where: { $0.id == id }) { entries[i].deadline = deadline }
    }

    // MARK: Leaving

    /// Removes one entry (answered, dismissed, timed out, connection dropped).
    @discardableResult
    public mutating func remove(_ id: UUID) -> InboxEntry? {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return nil }
        return entries.remove(at: i)
    }

    /// The owner went to the tab: removes its level-1 and held entries (never approvals).
    /// Returns the removed held entries so the caller can reply "no decision" to each.
    public mutating func wentToTerminal(_ tabID: UUID) -> [InboxEntry] {
        let held = entries.filter { $0.tabID == tabID && $0.isHeld }
        entries.removeAll { $0.tabID == tabID && ($0.isHeld || Inbox.isLevelOne($0)) }
        return held
    }

    /// Tab closed: like `wentToTerminal`, plus approvals for that tab and all bookkeeping.
    /// Returns the removed held and approval entries.
    public mutating func tabClosed(_ tabID: UUID) -> [InboxEntry] {
        let gone = entries.filter { $0.tabID == tabID && !Inbox.isLevelOne($0) }
        entries.removeAll { $0.tabID == tabID }
        workingTabs.remove(tabID)
        speaksStatus.remove(tabID)
        lastMessages[tabID] = nil
        return gone
    }

    // MARK: Helpers

    private static func isLevelOne(_ e: InboxEntry) -> Bool {
        switch e.kind {
        case .waiting, .done: true
        default: false
        }
    }

    private func levelOneIndex(of tabID: UUID, excluding: UUID? = nil) -> Int? {
        entries.firstIndex { $0.tabID == tabID && Inbox.isLevelOne($0) && $0.id != excluding }
    }

    private mutating func removeLevelOne(of tabID: UUID) {
        entries.removeAll { $0.tabID == tabID && Inbox.isLevelOne($0) }
    }

    /// Removes the tab's matching held entries and queues them for `takeReleased`.
    private mutating func release(_ tabID: UUID, where matches: (InboxEntry) -> Bool) {
        let gone = entries.filter { $0.tabID == tabID && $0.isHeld && matches($0) }
        guard !gone.isEmpty else { return }
        let ids = Set(gone.map(\.id))
        entries.removeAll { ids.contains($0.id) }
        released.append(contentsOf: gone)
    }
}
