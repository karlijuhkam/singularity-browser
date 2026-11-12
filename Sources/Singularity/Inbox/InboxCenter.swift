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

    /// A Claude Code hook call held open until the owner answers it in the inbox (a question or a
    /// permission request, see `hookArrived`). Kept by entry id until it gets its one reply.
    private struct HeldRequest {
        let connection: any HookReplying
        let tabID: UUID
        /// The question's original `tool_input` as JSON text, which `ClaudeHook.answerReply` reads
        /// again (the entry holds only cleaned text). Nil for a permission request.
        let toolInput: String?
        var timer: Task<Void, Never>?
    }
    @ObservationIgnored private var heldRequests: [UUID: HeldRequest] = [:]

    /// How long a request is held before it goes back to the terminal (its entry stays as a plain
    /// waiting entry). Safely below the hook's own `timeout` of 3600 s: when that runs out first,
    /// Claude Code kills the helper and the owner's answer would be lost. Tests shorten it.
    @ObservationIgnored var holdLimit: Duration = .seconds(3300)

    /// At most this many requests are held per tab; one more gets "no decision" at once (its
    /// prompt appears in the terminal). Bounds open connections and entries, e.g. for a runaway
    /// loop of nested `claude -p` runs, which inherit the tab's variables.
    static let maxHeldPerTab = 5

    /// The tab's shell process id, for the check that a hook request comes from inside that tab.
    /// Nil: ask the tab's terminal session. Tests set it (their helper is the test's own child).
    @ObservationIgnored var tabShellPID: ((UUID) -> pid_t?)?

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
        guard answerClickCounts() else { return }
        decideApproval(id, outcome)
    }

    /// An option or Send on a question card (through `perform`); under the same lock.
    func answerQuestionFromCard(_ id: UUID, answers: [String: [String]]) {
        guard answerClickCounts() else { return }
        answerQuestion(id, answers: answers)
    }

    /// Allow or Deny on a permission card (through `perform`); under the same lock.
    func decidePermissionFromCard(_ id: UUID, allow: Bool) {
        guard answerClickCounts() else { return }
        decidePermission(id, allow: allow)
    }

    /// Whether an answer click counts now (see `answersUnlockAt`).
    private func answerClickCounts() -> Bool {
        guard now() >= answersUnlockAt else {
            logChange("answer click ignored: the cards just moved", tabID: nil)
            return false
        }
        return true
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

    // MARK: Claude Code's questions and permission requests (held hook calls)

    /// A hook call from `singularity-hook`, relayed by the hook socket. Decides at once, or holds
    /// it as an entry until the owner answers. Every call gets exactly one reply on `connection`:
    /// First the acknowledgement byte, written here on the main actor: the helper waits for it a
    /// few seconds, so a stuck app costs Claude Code seconds, not the hook's hour. Then:
    /// - a tab we don't know, a helper that does not run inside that tab's shell (see
    ///   `comesFromTheTab`), a hook that isn't ours, or the AskUserQuestion permission stage
    ///   (its dialog is the question itself): "no decision" at once;
    /// - Stop: "no decision" at once (it never waits), and its text becomes the done entry's;
    /// - a question or permission request while the owner looks at that terminal, or with
    ///   `maxHeldPerTab` already held for the tab: "no decision" at once, so Claude Code shows its
    ///   own prompt there;
    /// - otherwise held: answered in the inbox, or handed back to the terminal ("no decision") by
    ///   any of the ways listed at `finishHeld`.
    func hookArrived(tabID: UUID, hookInput: Data, connection: any HookReplying) {
        connection.acknowledge()
        guard let spaceID = state?.spaces.first(where: { $0.tab(tabID) != nil })?.id else {
            connection.reply(ClaudeHook.noDecision)
            return
        }
        guard comesFromTheTab(tabID, connection: connection) else {
            logChange("hook from outside the tab's shell: no decision", tabID: tabID)
            connection.reply(ClaudeHook.noDecision)
            return
        }
        switch ClaudeHook.parse(hookInput) {
        case .ignored:
            connection.reply(ClaudeHook.noDecision)
        case .stop(let lastMessage):
            connection.reply(ClaudeHook.noDecision)
            turnEnded(tabID: tabID, lastMessage: lastMessage)
        case .question(let questions, let toolInput):
            hold(.question(questions), toolInput: toolInput, tabID: tabID, spaceID: spaceID, connection: connection)
        case .permission(let tool, let input):
            hold(.permission(tool: tool, input: input), toolInput: nil, tabID: tabID, spaceID: spaceID,
                 connection: connection)
        }
    }

    /// The owner's answer to a held question: cleaned question text → cleaned labels, as the card
    /// shows them. `ClaudeHook.answerReply` maps them back to Claude Code's original strings; when
    /// nothing matches it gives "no decision", and the question goes back to the terminal.
    func answerQuestion(_ id: UUID, answers: [String: [String]]) {
        guard let toolInput = heldRequests[id]?.toolInput else { return }
        finishHeld(id, reply: ClaudeHook.answerReply(toolInput: toolInput, answers: answers), why: "question answered")
    }

    /// Allow (this once) or Deny for a held permission request.
    func decidePermission(_ id: UUID, allow: Bool) {
        guard heldRequests[id] != nil,
              case .permission = inbox.entries.first(where: { $0.id == id })?.kind else { return }
        finishHeld(id, reply: ClaudeHook.permissionReply(allow: allow), why: allow ? "permission allowed" : "permission denied")
    }

    /// The app is quitting: every held request goes back to its terminal. (Were this missed,
    /// the helper would still get an empty reply when the app's end closes the connection.)
    func handBackAllHeld() {
        for id in Array(heldRequests.keys) {
            finishHeld(id, reply: ClaudeHook.noDecision, why: "app quitting")
        }
    }

    /// SINGULARITY_TAB is inherited by everything started in the tab, including a tmux or screen
    /// server that later serves panes in Terminal.app; Claude Code there must not send its
    /// questions here. So the helper must run inside this tab's shell: a descendant of its
    /// process. Peer or shell unknown: "no". (A tmux server started inside a herdr-core shell
    /// still counts as inside; accepted.)
    private func comesFromTheTab(_ tabID: UUID, connection: any HookReplying) -> Bool {
        guard let peer = connection.peerPID,
              let shell = tabShellPID?(tabID) ?? state?.terminals.existingSession(tabID)?.shellPID else { return false }
        return ProcessInspector.isDescendant(peer, of: shell)
    }

    private func hold(_ kind: InboxKind, toolInput: String?, tabID: UUID, spaceID: UUID, connection: any HookReplying) {
        guard heldRequests.values.filter({ $0.tabID == tabID }).count < Self.maxHeldPerTab else {
            logChange("already \(Self.maxHeldPerTab) held for the tab: no decision", tabID: tabID)
            connection.reply(ClaudeHook.noDecision)
            return
        }
        let program = state?.terminals.existingSession(tabID)?.foregroundProgram
        let tab = facts(tabID: tabID, spaceID: spaceID, foregroundProgram: program)
        let agent = InboxRules.agentName(statusApp: "claude-code", foregroundProgram: program)
        guard let entry = inbox.hold(kind, tab: tab, agent: agent, now: now()) else {
            // The owner is looking at the terminal: its own prompt appears there at once.
            connection.reply(ClaudeHook.noDecision)
            return
        }
        heldRequests[entry.id] = HeldRequest(connection: connection, tabID: tabID, toolInput: toolInput)
        startHoldTimer(entry.id)
        // Set after the record exists: if the helper is already gone, this calls back at once.
        let id = entry.id
        connection.onClosedByPeer = { [weak self] in
            Task { @MainActor in self?.finishHeld(id, reply: nil, why: "hook went away") }
        }
        logChange(toolInput == nil ? "permission held" : "question held", tabID: tabID)
        listDidChange()
        onArrival(entry)
    }

    /// Stop: the agent's turn ended. Its last message becomes the done entry's text; held
    /// requests of the tab can no longer be answered and go back ("no decision").
    private func turnEnded(tabID: UUID, lastMessage: String?) {
        var updated = inbox
        var released: [InboxEntry]
        if let lastMessage {
            updated.noteLastMessage(lastMessage, tabID: tabID)
            released = updated.takeReleased()
        } else {
            // No text: leave the done entry's text alone, release the held requests all the same.
            released = updated.entries.filter { $0.tabID == tabID && $0.isHeld }
            for entry in released { updated.remove(entry.id) }
        }
        if store(updated) {
            logChange("stop", tabID: tabID)
            listDidChange()
        }
        releaseHeld(released)
    }

    /// The hold limit: hand the request back to the terminal and keep a plain waiting entry.
    private func startHoldTimer(_ id: UUID) {
        let limit = holdLimit
        heldRequests[id]?.timer = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: limit)
            } catch {
                return   // cancelled: ended some other way
            }
            guard let self, self.heldRequests[id] != nil else { return }
            // Reply first: `demote` gives the entry a new id, which no connection belongs to.
            self.finishHeld(id, reply: ClaudeHook.noDecision, why: "hold limit", removeEntry: false)
            self.inbox.demote(id)
            self.listDidChange()
        }
    }

    /// The one place a held request ends. Its record is taken out first, so whatever comes later
    /// for the same id finds nothing and does nothing: one reply per request, as for approvals.
    /// Ends: answered (`answerQuestion`), decided (`decidePermission`), handed back by the owner
    /// going to the terminal, the tab closing (also when its Space is deleted), the tab's status
    /// or a Stop releasing it, dismissal (`releaseHeld`), the hold limit, the app quitting
    /// (`handBackAllHeld`), and the helper going away (`reply` nil: nobody to answer).
    /// - Parameter removeEntry: false when the caller has already removed or will replace it.
    private func finishHeld(_ id: UUID, reply: Data?, why: String, removeEntry: Bool = true) {
        guard let held = heldRequests.removeValue(forKey: id) else { return }
        held.timer?.cancel()
        held.connection.onClosedByPeer = nil
        let removed = removeEntry ? inbox.remove(id) : nil
        if removed != nil { listDidChange() }
        logChange(why, tabID: held.tabID)
        if let reply { held.connection.reply(reply) }
    }

    /// Tests only: replaces the whole list (built with Core's `Inbox` methods) without announcing
    /// anything.
    func replaceInboxForTesting(_ inbox: Inbox) {
        self.inbox = inbox
    }

    // MARK: Helpers

    /// Entries that left the inbox while an agent (or a page) still waits for an answer: held hook
    /// requests and browser approvals. An approval that left without an answer (tab closed,
    /// dismissed) is denied; a held request goes back to the terminal ("no decision").
    private func releaseHeld(_ entries: [InboxEntry]) {
        for entry in entries {
            if Self.isApproval(entry) {
                finishApproval(entry.id, .denied)
            } else if entry.isHeld {
                finishHeld(entry.id, reply: ClaudeHook.noDecision, why: "handed back to the terminal")
            }
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
