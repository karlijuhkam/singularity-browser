import AppKit
import Observation
import SingularityCore

/// The app's side of the agent inbox: owns the Core `Inbox` (all the rules live there) and feeds
/// it what happens in the app: terminal signals from `TerminalSession`, and the owner going to a
/// terminal or closing it (from `AppState`).
///
/// "Looked at" is decided once, when something arrives (`facts`): app active, window key, tab on
/// screen. After that only deliberate actions remove an entry (`wentToTerminal`), never the app
/// merely becoming active again; see the spec's "Leaving".
///
/// Nothing here is saved to disk. Log lines carry kinds, tab ids and counts, never agent text.
@MainActor
@Observable
final class InboxCenter {
    private(set) var inbox = Inbox()
    var isPanelShown = false

    @ObservationIgnored weak var state: AppState?
    /// Tests replace these.
    @ObservationIgnored var now: () -> Date = { Date() }
    @ObservationIgnored var appIsActive: () -> Bool = { NSApp.isActive }
    @ObservationIgnored var windowIsKey: () -> Bool = { NSApp.mainWindow?.isKeyWindow ?? false }
    /// Called with every announce-worthy entry (Task 5 hooks the notifier in here).
    @ObservationIgnored var onArrival: (InboxEntry) -> Void = { _ in }
    /// Called whenever the list changed (Task 5: withdraw notifications, Dock badge).
    @ObservationIgnored var onChange: () -> Void = {}

    // MARK: Signals

    func facts(tabID: UUID, spaceID: UUID, foregroundProgram: String?) -> TabFacts {
        let lookedAt = InboxRules.isLookedAt(appIsActive: appIsActive(), windowIsKey: windowIsKey(),
                                             tabIsOnScreen: state?.isTabOnScreen(tabID) ?? false)
        return TabFacts(tabID: tabID, spaceID: spaceID, foregroundProgram: foregroundProgram, isLookedAt: lookedAt)
    }

    /// A terminal tab reported something: a status record, a notification, a bell, or that its
    /// program went away.
    func terminalSignal(_ signal: TerminalSignal, tabID: UUID, spaceID: UUID, foregroundProgram: String?) {
        let tab = facts(tabID: tabID, spaceID: spaceID, foregroundProgram: foregroundProgram)
        var statusApp: String?
        if case .status(let records) = signal { statusApp = InboxRules.summarise(records)?.app }
        let agent = InboxRules.agentName(statusApp: statusApp, foregroundProgram: foregroundProgram)

        // Work on a copy and store it only when it differs: status records arrive often (every
        // "working" update), and every write to `inbox` makes SwiftUI look at it again.
        var updated = inbox
        let change = updated.apply(signal, tab: tab, agent: agent, now: now())
        let released = updated.takeReleased()
        let listChanged = store(updated)

        if listChanged { logChange(Self.name(of: signal), tabID: tabID) }
        if listChanged { onChange() }
        if case .added(let entry) = change { onArrival(entry) }
        releaseHeld(released)
    }

    // MARK: The owner acts

    /// The owner went to this terminal on purpose: selected the tab, its split or its Space,
    /// or clicked or typed in it. Its waiting/done entry and held requests go; approvals stay.
    /// Called on every keystroke in a terminal, so it returns at once when there is nothing.
    func wentToTerminal(_ tabID: UUID) {
        guard inbox.entries.contains(where: { $0.tabID == tabID && !Self.isApproval($0) }) else { return }
        let held = inbox.wentToTerminal(tabID)
        logChange("went to terminal", tabID: tabID)
        onChange()
        releaseHeld(held)
    }

    /// The tab is gone: everything for it goes, approvals too.
    func tabClosed(_ tabID: UUID) {
        var updated = inbox
        let gone = updated.tabClosed(tabID)
        if store(updated) {
            logChange("tab closed", tabID: tabID)
            onChange()
        }
        releaseHeld(gone)
    }

    /// "Go to terminal" / "Show Tab" on a card: shows the tab and closes the panel. For anything
    /// but an approval this also counts as going to the terminal.
    func goTo(_ entry: InboxEntry) {
        isPanelShown = false
        guard let tabID = entry.tabID else { return }
        state?.showTab(tabID, in: entry.spaceID)
        // `showTab` already counts as going there; this clears the entry anyway when the tab is gone.
        if !Self.isApproval(entry) { wentToTerminal(tabID) }
    }

    func dismiss(_ id: UUID) {
        guard let removed = inbox.remove(id) else { return }
        logChange("dismissed", tabID: removed.tabID)
        onChange()
        if removed.isHeld || Self.isApproval(removed) { releaseHeld([removed]) }
    }

    // MARK: Helpers

    /// Entries that left the inbox while an agent (or a page) still waits for an answer: held hook
    /// requests and browser approvals. Nothing is held yet; Task 8 replies "no decision" to each
    /// held request here, and the approval tasks answer an approval that left this way.
    private func releaseHeld(_ entries: [InboxEntry]) {}

    /// Stores `updated` when it differs (bookkeeping included). Returns whether what the owner
    /// can see changed: the entries or the working tabs.
    private func store(_ updated: Inbox) -> Bool {
        guard updated != inbox else { return false }
        let listChanged = updated.entries != inbox.entries || updated.workingTabs != inbox.workingTabs
        inbox = updated
        return listChanged
    }

    private func logChange(_ what: String, tabID: UUID?) {
        terminalLog.notice("inbox: \(what, privacy: .public), tab \(tabID?.uuidString ?? "-", privacy: .public): \(self.inbox.count) entries, \(self.inbox.workingCount) more working")
    }

    private static func isApproval(_ entry: InboxEntry) -> Bool {
        if case .approval = entry.kind { true } else { false }
    }

    private static func name(of signal: TerminalSignal) -> String {
        switch signal {
        case .status(let records): "status \(InboxRules.summarise(records)?.state.rawValue ?? "none")"
        case .notification: "notification"
        case .bell: "bell"
        case .programExited: "program exited"
        }
    }
}
