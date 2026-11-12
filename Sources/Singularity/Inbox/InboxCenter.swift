import AppKit
import Observation
import SingularityCore

/// The app's side of the agent inbox: owns the Core `Inbox` (all the rules live there) and feeds
/// it what happens in the app: terminal signals from `TerminalSession`, the owner going to a
/// terminal or closing it (from `AppState`), and browser approvals (from `AgentApprovals`), which
/// wait here for the owner's answer.
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
    /// Whether the inbox panel is on screen. Change it through `showPanel` / `closePanel`.
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
    /// A browser approval arrived while Singularity is in the background: bounce the Dock icon
    /// once, as the approval sheet did. Tests replace it.
    @ObservationIgnored var requestAttention: () -> Void = { NSApp.requestUserAttention(.informationalRequest) }

    /// A browser approval waiting for the owner: the paused `AgentApprovals.check` (its
    /// continuation) and the clock. Kept by entry id until it is answered, exactly once.
    private struct WaitingApproval {
        let continuation: CheckedContinuation<AgentApprovals.Outcome, Never>
        let pending: AgentApprovals.PendingApproval
        var deadline: ContinuousClock.Instant
        var timer: Task<Void, Never>?
    }
    @ObservationIgnored private var waitingApprovals: [UUID: WaitingApproval] = [:]

    /// At most this many approvals wait at once per Space; one more is denied at once. The sheet
    /// showed one at a time, so a page calling `prompt()` in a loop could not flood anything;
    /// this keeps that true for entries, timers, notifications and Dock bounces.
    static let maxWaitingApprovalsPerSpace = 5

    /// Clicks on an approval's answer buttons (Allow, Allow on <site>, Deny) count only from this
    /// moment on. Moved `answerLockout` into the future when the panel appears and whenever a
    /// card is added, removed or moved: answering one card removes it and the next one moves up
    /// under the mouse, so the second click of a double-click on Deny could otherwise land on the
    /// next card's Allow; and a panel opening by itself could appear under a click meant for the
    /// window. A card whose text is updated in place does not move the lock: an agent rewriting
    /// its status quickly must not be able to keep the buttons locked.
    @ObservationIgnored private(set) var answersUnlockAt: Date = .distantPast
    static let answerLockout: TimeInterval = 0.5
    /// The visible entries' ids, in order, when `answersUnlockAt` was last moved.
    @ObservationIgnored private var lastVisibleIDs: [UUID] = []

    /// The rail's tray button (its AppKit view), so the panel can open beside it.
    @ObservationIgnored weak var railAnchor: NSView?
    @ObservationIgnored private var panelStorage: InboxPanelController?
    /// The panel, made the first time it is needed. Tests set its window through this.
    var panelController: InboxPanelController {
        if let existing = panelStorage { return existing }
        let controller = InboxPanelController(center: self)
        panelStorage = controller
        return controller
    }

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
        if listChanged { listDidChange() }
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
        listDidChange()
        releaseHeld(held)
    }

    /// The tab is gone: everything for it goes, approvals too.
    func tabClosed(_ tabID: UUID) {
        var updated = inbox
        let gone = updated.tabClosed(tabID)
        if store(updated) {
            logChange("tab closed", tabID: tabID)
            listDidChange()
        }
        releaseHeld(gone)
    }

    /// "Go to terminal" on a card: shows the tab and closes the panel. For anything but an
    /// approval this also counts as going to the terminal. (An approval's "Show Tab" is
    /// `showApprovalTab`: it keeps the panel open and restarts the clock.)
    func goTo(_ entry: InboxEntry) {
        if Self.isApproval(entry) {
            showApprovalTab(entry.id)
            return
        }
        closePanel()
        guard let tabID = entry.tabID else { return }
        state?.showTab(tabID, in: entry.spaceID)
        // `showTab` already counts as going there; this clears the entry anyway when the tab is gone.
        if !Self.isApproval(entry) { wentToTerminal(tabID) }
    }

    func dismiss(_ id: UUID) {
        guard let removed = inbox.remove(id) else { return }
        logChange("dismissed", tabID: removed.tabID)
        listDidChange()
        if removed.isHeld || Self.isApproval(removed) { releaseHeld([removed]) }
    }

    // MARK: Browser approvals

    /// `AgentApprovals`' presenter: adds an approval entry and waits for the owner's answer, the
    /// deadline (`.timedOut`), or the entry leaving another way (tab closed, Space deleted, app
    /// quitting: `.denied`). Never returns an allowed outcome on its own, except `.auto` for a
    /// request the rules let through at that moment (`releaseApprovalsThatNowPass`).
    func requestApproval(_ pending: AgentApprovals.PendingApproval) async -> AgentApprovals.Outcome {
        // A request for a Space or tab that is already gone: no entry, "no".
        if let state {
            guard let space = state.space(pending.spaceID) else { return .denied }
            if let tabID = pending.request.tabID, space.tab(tabID) == nil { return .denied }
        }
        // Too many already waiting in this Space: "no" at once, without an entry.
        let waitingInSpace = waitingApprovals.values.filter { $0.pending.spaceID == pending.spaceID }.count
        if waitingInSpace >= Self.maxWaitingApprovalsPerSpace {
            logChange("approval refused: \(waitingInSpace) already waiting in the Space", tabID: pending.request.tabID)
            return .denied
        }
        let request = pending.request
        let approval = InboxApproval(
            actor: request.actor, action: request.action, detail: request.detail, url: request.url,
            tabTitle: request.tabTitle, text: request.text,
            siteHost: pending.siteOrigin.map { URL(string: $0)?.host() ?? $0 })
        let arrived = now()

        // The check pauses here until `finishApproval` resumes it. The closure runs at once, on
        // the main actor, so the entry and its waiting record exist before anything can answer.
        return await withCheckedContinuation { continuation in
            let entry = inbox.addApproval(approval, spaceID: pending.spaceID, tabID: request.tabID,
                                          deadline: arrived.addingTimeInterval(Self.seconds(pending.timeout)),
                                          now: arrived)
            waitingApprovals[entry.id] = WaitingApproval(continuation: continuation, pending: pending,
                                                         deadline: .now + pending.timeout)
            startApprovalTimer(entry.id)
            logChange("approval added", tabID: entry.tabID)
            listDidChange()
            announceApproval(entry)
        }
    }

    /// The owner's answer from the card: `.approved`, `.approvedSite` or `.denied`. Anything else,
    /// or an entry that is no longer waiting, does nothing.
    func decideApproval(_ id: UUID, _ outcome: AgentApprovals.Outcome) {
        guard let waiting = waitingApprovals[id] else { return }
        switch outcome {
        case .approved, .denied:
            finishApproval(id, outcome)
        case .approvedSite:
            // Only offered when the rules name a site to allow.
            guard waiting.pending.siteOrigin != nil else { return }
            finishApproval(id, .approvedSite)
            // `AgentApprovals.check` records the site when its task runs on, which the line
            // above queued on the main actor; look at the other requests after that.
            Task { @MainActor [weak self] in
                await Task.yield()
                self?.releaseApprovalsThatNowPass()
            }
        case .auto, .timedOut, .refused:
            return
        }
    }

    /// "Show Tab" on the card: shows the tab the request is about and gives the owner the full
    /// time again. Does not answer, and does not take the entry away (going to a tab never
    /// removes approvals, see `wentToTerminal`).
    func showApprovalTab(_ id: UUID) {
        guard let waiting = waitingApprovals[id] else { return }
        if let showTab = waiting.pending.request.showTab {
            showTab()
        } else if let tabID = waiting.pending.request.tabID {
            state?.showTab(tabID, in: waiting.pending.spaceID)
        } else {
            return
        }
        // Showing the tab could have ended the request (it never should); then there is no clock.
        guard waitingApprovals[id] != nil else { return }
        let timeout = waiting.pending.timeout
        waitingApprovals[id]?.deadline = .now + timeout
        inbox.setDeadline(id, now().addingTimeInterval(Self.seconds(timeout)))
    }

    /// A click on an answer button of a card (through `perform`). Ignored, and nothing answered,
    /// while the answer buttons are locked (`answersUnlockAt`). `decideApproval` itself does not
    /// look at the lock.
    func answerFromCard(_ id: UUID, _ outcome: AgentApprovals.Outcome) {
        guard now() >= answersUnlockAt else {
            logChange("approval click ignored: the cards just moved", tabID: nil)
            return
        }
        decideApproval(id, outcome)
    }

    /// The panel came on screen: lock the answer buttons for a moment (see `answersUnlockAt`).
    func panelAppeared() {
        lockAnswers()
    }

    private func lockAnswers() {
        answersUnlockAt = now().addingTimeInterval(Self.answerLockout)
    }

    /// After any change of the list: lock the answer buttons when the set or order of visible
    /// cards changed (added, removed, moved; not a text updated in place), then tell the
    /// notifier (`onChange`).
    private func listDidChange() {
        let ids = inbox.visible.map(\.id)
        if ids != lastVisibleIDs {
            lastVisibleIDs = ids
            lockAnswers()
        }
        onChange()
    }

    /// After an "Allow on <site>": other waiting requests that the rules now let through go
    /// ahead (`.auto`). Each is asked at this moment; the always-ask cases never pass.
    private func releaseApprovalsThatNowPass() {
        for (id, waiting) in waitingApprovals where waiting.pending.passesNow() {
            finishApproval(id, .auto)
        }
    }

    /// The Space is being deleted: its waiting approvals (also those without a tab) are denied.
    func spaceDeleted(_ spaceID: UUID) {
        for (id, waiting) in waitingApprovals where waiting.pending.spaceID == spaceID {
            finishApproval(id, .denied)
        }
    }

    /// The app is quitting: every waiting approval is denied.
    func denyAllApprovals() {
        for id in waitingApprovals.keys {
            finishApproval(id, .denied)
        }
    }

    /// Answers a waiting approval and takes its entry away. Exactly once: the waiting record is
    /// taken out first, so any later call for the same id (a late answer, the timer, a tab
    /// closing) finds nothing and does nothing. Resuming a continuation twice would crash.
    private func finishApproval(_ id: UUID, _ outcome: AgentApprovals.Outcome) {
        guard let waiting = waitingApprovals.removeValue(forKey: id) else { return }
        waiting.timer?.cancel()
        if inbox.remove(id) != nil { listDidChange() }
        logChange("approval \(outcome.logValue)", tabID: waiting.pending.request.tabID)
        waiting.continuation.resume(returning: outcome)
    }

    /// Ends the request as `.timedOut` at its deadline. "Show Tab" moves the deadline, so the
    /// deadline is read again after every wake-up. The task holds the inbox strongly on purpose:
    /// a waiting request must always get its answer, so the inbox lives at least that long.
    private func startApprovalTimer(_ id: UUID) {
        waitingApprovals[id]?.timer = Task { @MainActor in
            while let deadline = self.waitingApprovals[id]?.deadline, ContinuousClock.now < deadline {
                do {
                    try await Task.sleep(until: deadline, clock: .continuous)
                } catch {
                    return   // cancelled: answered some other way
                }
            }
            self.finishApproval(id, .timedOut)
        }
    }

    /// Singularity active: the panel opens by itself, without the keyboard, and no notification
    /// (the owner is here). In the background, or when the panel could not open: a notification
    /// and a Dock bounce.
    private func announceApproval(_ entry: InboxEntry) {
        if appIsActive() {
            showPanel(takingFocus: false)
            if isPanelShown { return }
        }
        onArrival(entry)
        requestAttention()
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        let parts = duration.components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }

    /// Tests only: replaces the whole list (built with Core's `Inbox` methods) without announcing
    /// anything.
    func replaceInboxForTesting(_ inbox: Inbox) {
        self.inbox = inbox
    }

    // MARK: Helpers

    /// Entries that left the inbox while an agent (or a page) still waits for an answer: held hook
    /// requests and browser approvals. An approval that left without an answer (tab closed,
    /// dismissed) is denied. Nothing is held yet; Task 8 replies "no decision" to each held
    /// request here.
    private func releaseHeld(_ entries: [InboxEntry]) {
        for entry in entries where Self.isApproval(entry) {
            finishApproval(entry.id, .denied)
        }
    }

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
