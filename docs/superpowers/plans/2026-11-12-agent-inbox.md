# Agent Inbox Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One list, reachable from every Space, of agents that are waiting or done; questions, permission requests and the browser's own approvals can be answered in it.

**Architecture:** A pure `Inbox` value type in `SingularityCore` holds the entries and every rule (what a terminal signal, a hook message or an approval does to the list). The app's `InboxCenter` (owned by `AppState`) feeds it from SwiftTerm callbacks, a Unix socket that a small `singularity-hook` helper relays Claude Code hooks to, and `AgentApprovals`; it drives a rail button, a non-activating panel, macOS notifications and the Dock badge.

**Tech Stack:** Swift 6, SwiftUI + AppKit, SwiftTerm 1.99.3 (pinned), `UserNotifications` (system), Swift Testing. No new dependency.

**Spec:** `docs/superpowers/specs/2026-11-11-agent-inbox-design.md` (read it first; this plan argues from it).

## Global Constraints

- Work in the worktree `.claude/worktrees/inbox`, branch `inbox`. Never touch the main checkout; another agent works there.
- Builds: `source scripts/env.sh` first, or use the scripts. Never `xcode-select -s`.
- Never run plain `scripts/build-app.sh` or `scripts/run.sh` (they replace the owner's running bundle). Full bundle: `APP=/private/tmp/sg-app/Singularity.app scripts/build-app.sh`; run with `SINGULARITY_HOME=/private/tmp/sg-test`. Never quit the owner's copy.
- Never write to the owner's real `~/.claude/settings.json` from a test or a script. The installer takes the file path as a parameter.
- No new dependencies. Verify SwiftTerm and `UserNotifications` APIs in the checked-out sources / SDK before use.
- Everything an agent or page puts in an entry is untrusted: plain text only (`Text(verbatim:)`), cleaned by `InboxText.clean`.
- `AgentApprovalRules` is not changed. Unanswered approval = denied, logged as `timeout`.
- No inbox button is ever a default button (no `.keyboardShortcut(.defaultAction)`, no `keyEquivalent = "\r"`).
- Boring, readable Swift; comment the non-obvious AppKit parts (owner reads TypeScript/PHP more fluently).
- Nothing is saved to disk. No history.
- Names fixed here: env vars `SINGULARITY_TAB` (tab UUID) and `SINGULARITY_HOOK_SOCKET` (path); socket `<root>/.run/hook.sock`; helper `Contents/MacOS/singularity-hook`.
- Commit after every task, message prefix `Inbox: `.

## Review Focus

1. **Claude Code outside Singularity, or Singularity not running, with the hook installed:** the helper exits 0 with empty output at once; Claude Code behaves as if no hook existed. (Task 8, Step 6.)
2. **Hostile or huge agent text** (control characters, direction overrides, a 1 MB message, a question with 50 options): shown cleaned and shortened, never crashes or overflows the panel. (Task 1 `clean…` tests; Task 7 `parse…` tests.)
3. **A `settings.json` we don't understand** (not JSON, `hooks` is not an object, an event's value is not an array): left byte-for-byte unchanged, status `unreadable`. (Task 9 tests.)
4. **Tab closed, Space deleted or app quit while requests are held or approvals wait:** every held hook gets "no decision" (or a closed socket) so Claude Code is never stuck; every waiting approval resolves as denied. (Task 2 `tabClosed…` test; Task 6 and Task 8 tests.)
5. **The bare binary (`.build/out/Products/Debug/Singularity`, app tests) has no bundle:** `UNUserNotificationCenter.current()` traps without one. The notifier must do nothing there. (Task 5, Step 1.)

---

## File Structure

```
Sources/SingularityCore/Inbox/
  InboxEntry.swift          entry model (InboxEntry, InboxQuestion, InboxApproval)
  Inbox.swift               the list + every mutation rule, ordering, counts
  InboxSignals.swift        TerminalSignal, StatusRecord, summarising records, agent names, looked-at rule
  InboxText.swift           cleaning and shortening untrusted text
  ClaudeHook.swift          parse hook input, build hook replies, the wire line helper ↔ app
  ClaudeHookSettings.swift  the settings.json edit (status / install / remove)
Sources/Singularity/Inbox/
  InboxCenter.swift         @Observable owner of the Inbox; all entry points
  InboxViews.swift          rail button, counts, panel content (cards)
  InboxPanel.swift          the non-activating NSPanel that hosts the list
  InboxNotifier.swift       UNUserNotificationCenter wrapper + Dock badge
  HookSocket.swift          hook.sock listener, one held connection per request
Sources/singularity-hook/main.swift   relay only
Tests/SingularityCoreTests/InboxTests.swift, ClaudeHookTests.swift, ClaudeHookSettingsTests.swift
Tests/SingularityAppTests/ApprovalInboxTests.swift (replaces ApprovalSheetTests.swift), InboxPanelTests.swift
```

Modified: `TerminalSession.swift`, `HerdrCore.swift`, `AppState.swift`, `SpaceRail.swift`, `Commands.swift`, `AgentApprovals.swift`, `SettingsView.swift`, `Package.swift`, `scripts/build-app.sh`, `scripts/release.sh`, `CLAUDE.md`, the spec (an "As tested" section).

---

### Task 0: Live test (throwaway, no product code)

Everything about Claude Code hooks in the spec comes from documentation. Settle it before building.

**Files:**
- Create (scratch, not committed): a temp folder with `.claude/settings.json` (project-level hooks) and a hook script that appends its stdin to a log and prints a reply chosen by a file you edit.
- Modify: `docs/superpowers/specs/2026-11-11-agent-inbox-design.md` (append `## As tested (2026-11-…)`)

- [ ] **Step 1:** In the scratch project, with the owner's `claude` (2.1.322), record for each line what actually happened:
  1. `PreToolUse` matcher `AskUserQuestion`: exact stdin JSON (are `tool_input.questions[].question/header/options[].label/multiSelect` there?).
  2. Reply `{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","updatedInput":{…questions, "answers":{"<question text>":"<label>"}}}}`: is the question answered without a prompt? Try one question, two questions, multi-select (labels joined with `, `? with `,`?).
  3. Empty stdout + exit 0 after sleeping 5 s, 2 min, 15 min: does the normal prompt appear each time?
  4. Hook `timeout`: is `3600` accepted? What does Claude Code do when the hook outlives its timeout?
  5. `PermissionRequest`: stdin JSON; replies `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}` and `"deny"`; empty reply.
  6. `Stop`: stdin JSON, `last_assistant_message` present?
  7. Killing Claude Code (Ctrl-C, closing the terminal) while a hook sleeps: is the hook process killed / its stdin closed?
  8. OSC 7501: run `claude` under `script -q /tmp/…/typescript` and grep the raw bytes for `]7501;`; note which states/kinds are sent and when (start of turn, question, permission, end of turn).
  9. Hermes (`~/.local/bin/hermes`): same capture; does it send 7501, OSC 9/777, or BEL when it wants input or finishes?
- [ ] **Step 2:** Write the results into the spec's new "As tested" section, including the two numbers later tasks use: `hookTimeoutSeconds` and `holdLimitSeconds` (aim 3600 / 3300; lower both if Claude Code caps the timeout; hold limit must be at least 60 s below the timeout).
- [ ] **Step 3: Gate.** If item 2 or 5 does not work as documented, stop and report to the owner (spec: fallback is read-only question + "Go to terminal"). Otherwise commit the spec change: `Inbox: live test results`.

---

### Task 1: Core — entries, text clean-up, signals

**Files:**
- Create: `Sources/SingularityCore/Inbox/InboxEntry.swift`, `InboxText.swift`, `InboxSignals.swift`
- Test: `Tests/SingularityCoreTests/InboxTests.swift`

**Interfaces (Produces):**

```swift
public struct InboxQuestion: Equatable, Sendable {
    public var question: String; public var header: String?
    public var options: [String]          // labels, in order
    public var multiSelect: Bool
}
public struct InboxApproval: Equatable, Sendable {
    public var actor, action, detail: String
    public var url: String?; public var tabTitle: String?; public var text: String?
    public var siteHost: String?          // non-nil = offer "Allow on <siteHost>"
}
public enum InboxWaitingReason: String, Sendable { case question, permission, auth, error, attention }
public enum InboxKind: Equatable, Sendable {
    case question([InboxQuestion])                   // held Claude Code question
    case permission(tool: String, input: String)     // held Claude Code permission request
    case approval(InboxApproval)                     // browser approval
    case waiting(InboxWaitingReason)                 // level 1
    case done                                        // level 1
}
public struct InboxEntry: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var kind: InboxKind
    public var spaceID: UUID
    public var tabID: UUID?               // nil only for approvals without a tab
    public var agent: String              // "Claude Code"
    public var message: String?           // already cleaned
    public var arrived: Date
    public var deadline: Date?            // approvals only
    public var isHeld: Bool { get }       // .question or .permission
}

public enum InboxText {
    /// Removes control characters, direction overrides (U+202A…202E, U+2066…2069) and invisible
    /// formatting (U+200B…200F, U+2060, U+FEFF), collapses runs of whitespace to one space,
    /// trims, and cuts to `limit` characters with a trailing "…".
    public static func clean(_ text: String, limit: Int) -> String
    public static let messageLimit = 600
    public static let notificationLimit = 200
    public static let inputLimit = 4000   // permission input / approval text; keeps newlines and tabs
    public static func cleanBlock(_ text: String, limit: Int) -> String  // like clean, but keeps \n and \t
}

public enum ProgramState: String, Sendable { case idle, working, done, blocked, error }
public struct StatusRecord: Equatable, Sendable {
    public var id: String; public var state: ProgramState
    public var kind: InboxWaitingReason?  // question / permission / auth when blocked
    public var app: String?; public var message: String?
}
public enum TerminalSignal: Equatable, Sendable {
    case status([StatusRecord])           // all current records of the tab; [] = none left
    case notification(title: String, body: String)
    case bell
    case programExited                    // foreground went back to the shell, or the shell ended
}
public struct TabFacts: Equatable, Sendable {
    public var tabID, spaceID: UUID
    public var foregroundProgram: String? // nil = shell at its prompt
    public var isLookedAt: Bool
}
public enum InboxRules {
    /// One record speaks for the tab: the most urgent state wins
    /// (blocked > error > done > working > idle); ties go to the record with the shorter id.
    public static func summarise(_ records: [StatusRecord]) -> StatusRecord?
    /// claude → "Claude Code", codex → "Codex", hermes → "Hermes" (case-insensitive, matched on
    /// the status record's app first, then the foreground program); else the program name; else "Agent".
    public static func agentName(statusApp: String?, foregroundProgram: String?) -> String
    public static func isLookedAt(appIsActive: Bool, windowIsKey: Bool, tabIsOnScreen: Bool) -> Bool  // all three
}
```

- [ ] **Step 1: Write the failing tests** in `InboxTests.swift` (suite `InboxTextTests`, `InboxRulesTests`):

```swift
@Test func cleanStripsControlAndDirectionCharacters() {
    #expect(InboxText.clean("a\u{1b}[31mb\u{202E}c\u{200B}d\n\n  e", limit: 100) == "a[31mbcd e")
}
@Test func cleanShortens() {
    #expect(InboxText.clean(String(repeating: "x", count: 1_000_000), limit: 600).count == 600)
    #expect(InboxText.clean(String(repeating: "x", count: 700), limit: 600).hasSuffix("…"))
}
@Test func cleanBlockKeepsNewlines() {
    #expect(InboxText.cleanBlock("a\n\tb\u{7}", limit: 100) == "a\n\tb")
}
@Test func summarisePicksTheMostUrgent() {
    let r = [StatusRecord(id: "", state: .working, kind: nil, app: "claude", message: nil),
             StatusRecord(id: "sub/1", state: .blocked, kind: .permission, app: nil, message: "Run npm?")]
    #expect(InboxRules.summarise(r)?.state == .blocked)
    #expect(InboxRules.summarise([]) == nil)
}
@Test func agentNames() {
    #expect(InboxRules.agentName(statusApp: "Claude", foregroundProgram: "node") == "Claude Code")
    #expect(InboxRules.agentName(statusApp: nil, foregroundProgram: "hermes") == "Hermes")
    #expect(InboxRules.agentName(statusApp: nil, foregroundProgram: "aider") == "aider")
    #expect(InboxRules.agentName(statusApp: nil, foregroundProgram: nil) == "Agent")
}
@Test func lookedAtNeedsAllThree() {
    #expect(InboxRules.isLookedAt(appIsActive: true, windowIsKey: true, tabIsOnScreen: true))
    #expect(!InboxRules.isLookedAt(appIsActive: false, windowIsKey: true, tabIsOnScreen: true))
}
```

  ("Claude" matches by prefix `claude`; write `agentName` so `claude`, `claude-code`, `Claude Code` all map.)
- [ ] **Step 2:** `source scripts/env.sh && swift test --filter InboxT` → FAIL (types missing).
- [ ] **Step 3:** Implement the three files to the signatures above.
- [ ] **Step 4:** `swift test --filter Inbox` → PASS.
- [ ] **Step 5:** Commit `Inbox: entry model, text clean-up, signals (Core)`.

---

### Task 2: Core — the Inbox and its rules

**Files:**
- Create: `Sources/SingularityCore/Inbox/Inbox.swift`
- Test: `Tests/SingularityCoreTests/InboxTests.swift` (suite `InboxListTests`)

**Interfaces:**
- Consumes: Task 1 types.
- Produces:

```swift
public struct Inbox: Equatable, Sendable {
    public init()
    public private(set) var entries: [InboxEntry]            // storage order = arrival
    public private(set) var workingTabs: Set<UUID>

    public var ordered: [InboxEntry] { get }   // approvals, then held (question/permission), then waiting, then done; oldest first in each
    public var count: Int { get }              // level-1 entries hidden behind a held one are not counted
    public func count(spaceID: UUID) -> Int
    public var visible: [InboxEntry] { get }   // `ordered` minus level-1 entries of tabs that have a held entry
    public var workingCount: Int { get }       // workingTabs not represented by a visible entry

    public enum Change: Equatable, Sendable {
        case none
        case added(InboxEntry)                 // notify-worthy
        case changed                           // list differs, nothing new to announce
    }
    /// Level 1. Rules:
    /// - .status: summarise; working → remove the tab's level-1 entry, add to workingTabs;
    ///   idle / no records → remove entry and from workingTabs; blocked → waiting(kind ?? .attention);
    ///   error → waiting(.error); done → done. message = clean(record.message).
    ///   A tab that has ever sent a status record is marked "speaks status": later .bell and
    ///   .notification from it are ignored until .programExited.
    /// - .notification → waiting(.attention), message = clean(body, or title when body is empty).
    /// - .bell → waiting(.attention) only when facts.foregroundProgram != nil.
    /// - .programExited → remove the tab's level-1 entry, workingTabs, and the "speaks status" mark.
    /// - Any entry-creating signal while facts.isLookedAt → no entry (but workingTabs is still kept right).
    /// - Same state as the existing entry → update its message in place, keep `arrived`, return .changed (no new announcement).
    public mutating func apply(_ signal: TerminalSignal, tab: TabFacts, agent: String, now: Date) -> Change

    /// Level 2. Returns nil (caller replies "no decision") when tab.isLookedAt.
    public mutating func hold(_ kind: InboxKind, tab: TabFacts, agent: String, now: Date) -> InboxEntry?
    /// Text for a done entry from the Stop hook: sets the message of the tab's done entry,
    /// or remembers it for the done entry that the status record creates right after.
    public mutating func noteLastMessage(_ text: String, tabID: UUID)

    public mutating func addApproval(_ approval: InboxApproval, spaceID: UUID, tabID: UUID?, deadline: Date, now: Date) -> InboxEntry
    public mutating func setDeadline(_ id: UUID, _ deadline: Date)

    /// Removes one entry (answered, dismissed, timed out, connection dropped). Returns it.
    @discardableResult public mutating func remove(_ id: UUID) -> InboxEntry?
    /// The owner went to the tab: removes its level-1 and held entries (never approvals).
    /// Returns the removed held entries so the caller can reply "no decision" to each.
    public mutating func wentToTerminal(_ tabID: UUID) -> [InboxEntry]
    /// Tab closed: like wentToTerminal, plus approvals for that tab. Returns removed held and approval entries.
    public mutating func tabClosed(_ tabID: UUID) -> [InboxEntry]
    /// Hold limit reached: removes the held entry and puts a level-1 waiting entry
    /// (same reason: .question / .permission) in its place, same `arrived`.
    public mutating func demote(_ id: UUID)
}
```

- [ ] **Step 1: Write the failing tests.** One `@Test` per rule; each builds `var inbox = Inbox()` and a `facts(looked: Bool = false, program: String? = "claude")` helper. Required cases and assertions:
  - `blockedCreatesWaitingEntry`: `.status([blocked, kind .question, message "Pick one"])` → `.added`, `visible.count == 1`, kind `.waiting(.question)`, message `"Pick one"`.
  - `workingRemovesEntryAndCounts`: blocked then working → `visible.isEmpty`, `workingCount == 1`.
  - `doneThenIdleRemoves`; `errorIsWaiting`.
  - `nothingWhileLookedAt`: blocked with `looked: true` → `.none`, `visible.isEmpty`.
  - `sameStateDoesNotAnnounceTwice`: blocked twice → second returns `.changed`, `arrived` unchanged.
  - `bellNeedsAForegroundProgram`: `.bell` with `program: nil` → `.none`; with `"hermes"` → `.added`.
  - `bellIgnoredAfterStatus`: status(working) then `.bell` → `.none`; then `.programExited` then `.bell` (program `"vim"`) → `.added`.
  - `notificationUsesBodyThenTitle`.
  - `heldHidesLevelOne`: status(blocked) then `hold(.question…)` → `visible.count == 1` and it is the held one; `count == 1`.
  - `holdRefusedWhileLookedAt` → `nil`.
  - `severalHeldPerTab`: two `hold(.permission…)` on one tab → two visible entries.
  - `wentToTerminalReturnsHeldAndKeepsApprovals`: one held, one level-1, one approval for the same tab → returns 1 held; `visible` has only the approval.
  - `tabClosedReturnsHeldAndApprovals`.
  - `demoteLeavesAWaitingEntry`: hold question, `demote` → `visible.first?.kind == .waiting(.question)`.
  - `stopMessageLandsOnDoneEntry`: `noteLastMessage("All tests pass", …)` then status(done) → message `"All tests pass"`; and the other order.
  - `orderIsApprovalsHeldWaitingDone`: add done, waiting (other tab), held, approval at increasing times → `visible.map(kindName) == ["approval","permission","waiting","done"]`.
  - `countsPerSpace`: entries in two Spaces → `count(spaceID:)` 2 and 1, `count == 3`.
- [ ] **Step 2:** `swift test --filter InboxListTests` → FAIL.
- [ ] **Step 3:** Implement `Inbox`.
- [ ] **Step 4:** `swift test --filter Inbox` → PASS.
- [ ] **Step 5:** Commit `Inbox: the list and its rules (Core)`.

---

### Task 3: App — InboxCenter and terminal signals

**Files:**
- Create: `Sources/Singularity/Inbox/InboxCenter.swift`
- Modify: `Sources/Singularity/Terminal/TerminalSession.swift`, `Sources/Singularity/App/AppState.swift`
- Test: `Tests/SingularityAppTests/InboxPanelTests.swift` (suite `InboxCenterTests`, nested in `AppTests`, starts `MainRunLoopGuard`)

**Interfaces:**
- Consumes: `Inbox`, `TerminalSignal`, `TabFacts`, `InboxRules`.
- Produces:

```swift
@MainActor @Observable final class InboxCenter {
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

    func facts(tabID: UUID, spaceID: UUID, foregroundProgram: String?) -> TabFacts
    func terminalSignal(_ signal: TerminalSignal, tabID: UUID, spaceID: UUID, foregroundProgram: String?)
    func wentToTerminal(_ tabID: UUID)      // deliberate: tab/Space/pane selected, click or key in the terminal
    func tabClosed(_ tabID: UUID)
    func goTo(_ entry: InboxEntry)          // state.showTab, then wentToTerminal for terminal entries; closes the panel
    func dismiss(_ id: UUID)
}
extension AppState {
    let inbox: InboxCenter                  // created in init, inbox.state = self
    func isTabOnScreen(_ tabID: UUID) -> Bool   // selected Space's visibleTabIDs contains it
}
```

- `TerminalSession`:
  - `programStatusChanged(source:records:)` (already part of `LocalProcessTerminalViewDelegate`, main actor): map `TerminalProgramStatus` → `StatusRecord` and call `state?.inbox.terminalSignal(.status(…), …)`.
  - Bell: in `SingularityTerminalView` override `nonisolated open func bell(source: Terminal)`; call `super`, then hop to the main actor and call an `onBell` closure the session sets.
  - Notifications: SwiftTerm's `notify(source:title:body:)` on the view is not `open`. In `didStartProcess()` register OSC handlers on `view.getTerminal()`: `registerOscHandler(code: 777)` (payload `notify;<title>;<body>`) and `registerOscHandler(code: 9)` (payload is the text; **ignore payloads starting with `4;`**, that is the progress report, and anything that is only digits and semicolons). Handlers run on SwiftTerm's I/O path: copy the bytes, hop to the main actor. Check in `Terminal.swift` that registering code 9 does not disable the built-in `9;4` progress handling; if it does, re-dispatch those payloads or skip code 9 and note it in the spec's "As tested".
  - In `refresh()`: when the foreground program changes to `nil` (back at the shell), send `.programExited`. In `processTerminated` too.
  - Deliberate attention: `SingularityTerminalView` overrides `mouseDown(with:)` and `keyDown(with:)` (call `super`) → `onUserInput` closure → `state?.inbox.wentToTerminal(tabID)`.
- `AppState`: call `inbox.wentToTerminal` for every tab in the selected Space's `visibleTabIDs` at the end of `selectTab`, `selectSpace`, `focusPane`, `showTab`; call `inbox.tabClosed` in `closeTab` and for each tab in `deleteSpace`. **Not** on app activation.

- [ ] **Step 1: Write the failing tests** (`InboxCenterTests`): build an `AppState` the way `SpaceDeleteTests` does (temp `SINGULARITY_HOME`-style root), two Spaces, a terminal tab in the second; set `center.appIsActive = { true }`, `windowIsKey = { true }`.
  - `signalFromAnotherSpaceCreatesAnEntryAndAnnounces`: blocked signal for the tab in the unselected Space → `inbox.visible.count == 1`, `onArrival` called once.
  - `signalFromTheTabOnScreenDoesNothing`: select that Space and tab first → no entry, `onArrival` not called.
  - `inactiveAppStillCreatesAnEntryForTheTabOnScreen`: `appIsActive = { false }` → entry.
  - `selectingTheTabRemovesItsEntry`: entry exists → `state.showTab(tab, in: space)` → empty.
  - `closingTheTabRemovesItsEntry`.
- [ ] **Step 2:** `swift test --filter InboxCenterTests` → FAIL.
- [ ] **Step 3:** Implement `InboxCenter`, the `AppState` hooks, the `TerminalSession` forwarding.
- [ ] **Step 4:** `swift test --filter InboxCenterTests` → PASS; `scripts/test.sh` → all green.
- [ ] **Step 5:** By hand: `SINGULARITY_HOME=/private/tmp/sg-test .build/out/Products/Debug/Singularity`, open a terminal, run `printf '\e]777;notify;Test;hello\a'` from a second Space's terminal after `sleep 3` while looking at the first Space; confirm in the debugger/log that an entry exists (UI comes in Task 4; add a `terminalLog.notice` line per inbox change and keep it).
- [ ] **Step 6:** Commit `Inbox: InboxCenter, terminal status, bell and notification signals`.

---

### Task 4: The rail button and the panel

**Files:**
- Create: `Sources/Singularity/Inbox/InboxViews.swift`, `Sources/Singularity/Inbox/InboxPanel.swift`
- Modify: `Sources/Singularity/Sidebar/SpaceRail.swift`, `Sources/Singularity/App/Commands.swift`
- Test: `Tests/SingularityAppTests/InboxPanelTests.swift` (suite `InboxPanelTests`)

**Interfaces:**
- Consumes: `InboxCenter` (Task 3).
- Produces:

```swift
/// The tray at the top of the rail: count badge, toggles the panel.
struct InboxRailButton: View
/// Small red count on a Space circle; hidden at 0. Used by SpaceDot.
struct InboxCountBadge: View { let count: Int }
/// The list. `onAction` closures come from InboxCenter; later tasks add cases.
struct InboxListView: View
@MainActor final class InboxPanelController {
    init(center: InboxCenter)
    /// - Parameter takingFocus: true when the owner opened it (click, menu, shortcut);
    ///   false when the app opens it by itself (Task 6).
    func show(relativeTo anchor: NSView?, takingFocus: Bool)
    func close()
    var isShown: Bool { get }
    var panel: NSPanel? { get }   // for tests
}
extension InboxCenter {
    func showPanel(takingFocus: Bool)   // sets isPanelShown, asks the controller
    func closePanel()
}
```

- Panel: `NSPanel`, style `[.nonactivatingPanel, .borderless]`, `becomesKeyOnlyIfNeeded = true`, `hidesOnDeactivate = false`, floating child of the main window (`addChildWindow(_:ordered: .above)`), 330 pt wide, height fits content up to 70 % of the window, then scrolls. Placed with its top-left 6 pt right of the rail button. Closes on: Esc while key, a click outside it (local `NSEvent` monitor for `.leftMouseDown` in the main window), the tray button, `goTo`. With `takingFocus: false` it must not become key and must not change the main window's first responder. Comment why a panel and not `.popover` (a popover takes key focus; see the spec's "Keyboard and the self-opening panel").
- Never put `.help()` on the tray button if it ends up inside the title-bar strip (see CLAUDE.md, Split view notes); the rail starts below it, so check.
- Card layout per the spec ("The list"): first line = Space colour dot, agent in semibold, "Space · folder" (terminal entries: `HomePath`-abbreviated working directory of the tab; approvals: site host · tab title), state chip (`asks`, `permission`, `waiting`, `done · 4 min`; approvals: time left, updated each second by a `TimelineView`). Body by kind; in this task implement `.waiting` (message or "Waiting for you") and `.done` (message, Dismiss). Every terminal card: "Go to terminal". Header: "Inbox" + "N more agents working" when `inbox.workingCount > 0`. Empty: "Nothing is waiting."
- All agent text through `Text(verbatim:)`.
- Rail: `InboxRailButton` above the `ForEach` in `SpaceRail`; `SpaceDot` gets `InboxCountBadge(count: state.inbox.inbox.count(spaceID: space.id))` as a top-trailing overlay. Tray badge = `inbox.count`; tray dimmed (`.secondary`) at 0.
- `Commands.swift`: "Show Inbox" in the View-ish group, shortcut ⌃⌘I (verify it is free in `Commands.swift`; pick another free one otherwise), action `state.inbox.showPanel(takingFocus: true)`. Add the same entry to the command palette's command list (find where "New Terminal" etc. are listed).

- [ ] **Step 1: Write the failing tests** (`InboxPanelTests`, off-screen window like `ApprovalSheetTests`):
  - `selfOpenedPanelDoesNotTakeFocus`: main window key with an `NSTextField` as first responder → `show(relativeTo: nil, takingFocus: false)` → `window.isKeyWindow`, `window.firstResponder` unchanged, `panel.isVisible`.
  - `noDefaultButtonInThePanel`: with one entry of every kind in the inbox (use a test-only initialiser on `InboxCenter` or feed it through the public entry points), walk the panel's view tree: no `NSButton` has `keyEquivalent == "\r"`.
  - `escClosesWithoutAnswering`: `takingFocus: true`, send Esc → `!isShown`, entry still in `inbox.visible`.
- [ ] **Step 2:** `swift test --filter InboxPanelTests` → FAIL.
- [ ] **Step 3:** Implement views, panel, rail changes, command.
- [ ] **Step 4:** Tests PASS; `scripts/test.sh` green.
- [ ] **Step 5:** By hand in the test copy: trigger a waiting and a done entry from a second Space (`printf '\e]777;notify;T;waiting\a'`; for done, run real `claude` and let a turn finish), check counts on tray and Space circle, the panel, "Go to terminal" switching Space, Dismiss, the "more agents working" line, light and dark mode.
- [ ] **Step 6:** Commit `Inbox: rail button, counts and the panel`.

---

### Task 5: macOS notification and Dock badge

**Files:**
- Create: `Sources/Singularity/Inbox/InboxNotifier.swift`
- Modify: `Sources/Singularity/App/AppState.swift` (wire `onArrival` / `onChange`), `Sources/Singularity/App/SingularityApp.swift` (delegate set at launch)

**Interfaces:**
- Consumes: `InboxCenter.onArrival`, `onChange`, `showPanel(takingFocus:)`.
- Produces:

```swift
/// What a notification says; pure, in Core (Sources/SingularityCore/Inbox/InboxSignals.swift).
public enum InboxNotificationText {
    /// title "<agent> · <Space name>"; body by kind: question → first question text;
    /// permission → "Wants to use <tool>"; approval → "Wants to <action>"; waiting → message ?? "Waiting for you";
    /// done → message ?? "Finished". Body cleaned to InboxText.notificationLimit.
    public static func make(_ entry: InboxEntry, spaceName: String) -> (title: String, body: String)
}
@MainActor final class InboxNotifier: NSObject, UNUserNotificationCenterDelegate {
    init(onOpen: @escaping @MainActor () -> Void)     // notification clicked
    func post(_ entry: InboxEntry, spaceName: String) // identifier = entry.id.uuidString
    func sync(with entries: [InboxEntry])             // withdraw delivered ones whose entry is gone; Dock badge = entries.count (nil at 0)
}
```

- [ ] **Step 1:** `InboxNotifier` does nothing at all when `Bundle.main.bundleIdentifier == nil` (the bare binary and tests; `UNUserNotificationCenter.current()` traps there). Guard every method; comment why.
- [ ] **Step 2: Failing test** in `InboxTests.swift`: `notificationText` — a held question entry with agent "Claude Code", Space "Work", question "Which database?" → `("Claude Code · Work", "Which database?")`; a done entry without message → body `"Finished"`.
- [ ] **Step 3:** Implement. Permission is requested (`requestAuthorization(options: [.alert, .badge])`) the first time `post` is called, not at launch; refused → `post` is a no-op, badge still set through `NSApp.dockTile.badgeLabel`. `willPresent` returns `[.banner]` so banners show while Singularity is active (the owner is in another Space). `didReceive` → `NSApp.activate`, `onOpen()` → `center.showPanel(takingFocus: true)`. No sound.
- [ ] **Step 4:** Wire: `inbox.onArrival = { notifier.post($0, spaceName: …) }` except browser approvals arriving while the app is active (Task 6 passes that through `onArrival` only when inactive); `inbox.onChange = { notifier.sync(with: inbox.inbox.visible) }`.
- [ ] **Step 5:** `scripts/test.sh` green. By hand with the **full bundle** (`APP=/private/tmp/sg-app/Singularity.app scripts/build-app.sh`, then run its binary with `SINGULARITY_HOME=/private/tmp/sg-test`): banner appears for an entry from another Space; clicking it opens the inbox; answering/dismissing withdraws it; Dock badge follows the count. Also: bare binary still launches.
- [ ] **Step 6:** Commit `Inbox: macOS notification and Dock badge`.

---

### Task 6: Browser approvals move into the inbox

**Files:**
- Modify: `Sources/Singularity/Agent/AgentApprovals.swift`, `Sources/Singularity/Inbox/InboxCenter.swift`, `Sources/Singularity/Inbox/InboxViews.swift`, `Sources/Singularity/App/AppState.swift`
- Delete: `Tests/SingularityAppTests/ApprovalSheetTests.swift`
- Test: `Tests/SingularityAppTests/ApprovalInboxTests.swift`

**Interfaces:**
- Consumes: `Inbox.addApproval`, `setDeadline`, `remove`.
- Produces:

```swift
extension AgentApprovals {
    /// Replaces the sheet. Set by AppState to `inbox.requestApproval`. Nil (tests without an inbox) = denied.
    var presenter: ((PendingApproval) async -> Outcome)? { get set }
    struct PendingApproval {
        var request: Request
        var spaceID: UUID
        var siteOrigin: String?
        var timeout: Duration
        /// True when the rules would now let it through without asking (after "Allow on site").
        var passesNow: @MainActor () -> Bool
    }
    /// Removed: isPresenting, presentingWindow, SheetControls, the NSAlert code.
}
extension InboxCenter {
    func requestApproval(_ pending: AgentApprovals.PendingApproval) async -> AgentApprovals.Outcome
    func decideApproval(_ id: UUID, _ outcome: AgentApprovals.Outcome)   // .approved / .approvedSite / .denied
    func showApprovalTab(_ id: UUID)   // runs request.showTab, restarts the deadline (now + timeout)
}
```

- `AgentApprovals.Request` gets `var tabID: UUID?` (set where requests are built: `AgentToolbox`, `sendPromptFromArtifact`), so the entry can carry it.
- `check` stays as is; `ask` builds a `PendingApproval` (`passesNow = { AgentApprovalRules.decide(context, policy: space.agentPolicy, allowedOrigins: self.allowedOrigins[space.id] ?? []) == .allow }` — compare with a `switch`, the type may not be `Equatable`) and awaits `presenter`.
- `requestApproval`: `inbox.addApproval(…, deadline: now + timeout)`; store a `CheckedContinuation` per entry id; a timer task per entry resumes with `.timedOut` at the deadline (re-read the deadline after waking; Show Tab moves it). App active → `showPanel(takingFocus: false)` and no notification; app inactive → `onArrival(entry)` and `NSApp.requestUserAttention(.informationalRequest)` (as the sheet did).
- After an `.approvedSite` answer has been recorded by `AgentApprovals.check` (i.e. on the next main-actor turn): for every other waiting approval whose `passesNow()` is true, resume with `.auto` and remove its entry.
- `tabClosed` / Space deleted: resume its approvals with `.denied`.
- Card (`.approval`): "<actor> wants to <action>" in semibold, detail, URL, the text in a scrolling monospaced box (max height 90 pt, `InboxText.cleanBlock`), buttons Allow, "Allow on <siteHost>" (only when non-nil), Deny, Show Tab. Chip: seconds left.

- [ ] **Step 1: Write the failing tests** (`ApprovalInboxTests`), porting every case of `ApprovalSheetTests` (read it first) to the inbox: instead of finding sheet buttons, wait until `center.inbox.visible` has the approval entry and call `decideApproval` / `showApprovalTab`. Cases and assertions:
  - `allowApproves`, `denyDenies`, `allowOnSiteIsRemembered` (second `check` for the same origin returns `.auto` without an entry).
  - `timeoutDenies`: `timeoutSeconds = { 5 }` → outcome `.timedOut`, `logValue == "timeout"`, entry gone.
  - `showTabRestartsTheClock`: call `showApprovalTab` at 3 s of 5 → still waiting at 6 s; the `showTab` closure ran once.
  - `twoRequestsWaitTogether`: two `check` calls → two entries; answering one leaves the other.
  - `allowOnSiteReleasesTheOtherRequestForThatSite`: two click requests on `https://example.com` → `.approvedSite` on the first → second returns `.auto`.
  - `alwaysAskIsNotReleased`: second request is a form submission (`AgentActionContext` kind that the rules always ask for; see `ApprovalTests.swift` for which) → still waiting after `.approvedSite`.
  - `closingTheTabDenies`.
  - `noPresenterDenies`: `AgentApprovals()` with `presenter == nil` and policy `.ask` → `.denied`.
- [ ] **Step 2:** `swift test --filter ApprovalInboxTests` → FAIL.
- [ ] **Step 3:** Implement; delete the sheet code and the old test file.
- [ ] **Step 4:** `scripts/test.sh` → all green (Core `ApprovalTests` untouched and passing).
- [ ] **Step 5:** By hand in the test copy with an agent connected (`SINGULARITY_MCP_SOCKET=$SINGULARITY_HOME/.run/mcp.sock`): a click needing approval opens the inbox by itself without stealing typing focus; Allow / Deny / timeout each land in the Agent activity pane with the right decision; `window.singularity.prompt()` from an artifact shows its text.
- [ ] **Step 6:** Commit `Inbox: browser approvals replace the approval sheet`.

---

### Task 7: Core — Claude Code hook messages

**Files:**
- Create: `Sources/SingularityCore/Inbox/ClaudeHook.swift`
- Test: `Tests/SingularityCoreTests/ClaudeHookTests.swift`

**Interfaces (Produces):** (adjust field names to Task 0's "As tested" if they differ; the shapes below are the documented ones)

```swift
public enum ClaudeHookEvent: Equatable, Sendable {
    /// `toolInput` is the original tool_input object as JSON text, echoed back in the reply.
    case question(questions: [InboxQuestion], toolInput: String)
    case permission(tool: String, input: String)     // input: pretty-printed tool_input, cleanBlock'ed to inputLimit
    case stop(lastMessage: String?)
    case ignored                                     // anything else, or unreadable
}
public enum ClaudeHook {
    public static func parse(_ hookInput: Data) -> ClaudeHookEvent
    /// answers: question text → chosen labels (one for single choice). Multi-select labels are
    /// joined with ", " (or what Task 0 found). Returns the PreToolUse reply JSON.
    public static func answerReply(toolInput: String, answers: [String: [String]]) -> Data
    public static func permissionReply(allow: Bool) -> Data
    public static let noDecision = Data()            // empty stdout, exit 0

    /// The line the helper sends: {"tab":"<uuid>","hook":<hook input>}\n
    public static func wireLine(tabID: String, hookInput: Data) -> Data
    public static func parseWireLine(_ line: Data) -> (tabID: UUID, hookInput: Data)?
    public static let maxWireBytes = 2_000_000       // longer lines are dropped → no decision
}
```

- At most 4 questions and 8 options per question are kept (extra ones dropped → treat the event as `.ignored`, so the prompt shows in the terminal untouched rather than partly).
- Question and option texts go through `InboxText.clean(…, limit: messageLimit)` for display, but `answerReply` must send back the **original** question text and label (keep both).

- [ ] **Step 1: Write the failing tests:**
  - `parseQuestion`: the JSON recorded in Task 0 (fallback: `{"hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Which database?","header":"DB","multiSelect":false,"options":[{"label":"SQLite","description":"…"},{"label":"Postgres","description":"…"}]}]}}`) → `.question` with one question, options `["SQLite","Postgres"]`.
  - `parsePermission`: `PermissionRequest` with `tool_name: "Bash"`, `tool_input: {"command":"npm run deploy"}` → `.permission(tool: "Bash", input:)` whose input contains `npm run deploy`.
  - `parseStop` → `.stop(lastMessage: "Done.")`.
  - `otherToolsAndGarbageAreIgnored`: PreToolUse for `Bash`; `Data("not json".utf8)`; `{}`; a question with 50 options → `.ignored`.
  - `answerReplyEchoesQuestionsAndAddsAnswers`: decode the reply → `hookSpecificOutput.hookEventName == "PreToolUse"`, `permissionDecision == "allow"`, `updatedInput.questions` equal to the input's, `updatedInput.answers == ["Which database?": "SQLite"]`.
  - `multiSelectJoinsLabels`.
  - `permissionReplies`: allow → `decision.behavior == "allow"`, no `updatedPermissions` key; deny → `"deny"`.
  - `wireLineRoundTrips`; `parseWireLine` of a line without a valid UUID → `nil`.
- [ ] **Step 2:** `swift test --filter ClaudeHookTests` → FAIL.
- [ ] **Step 3:** Implement with `JSONSerialization` (see `JSONText` in `Plugins/` for existing strict helpers).
- [ ] **Step 4:** PASS.
- [ ] **Step 5:** Commit `Inbox: Claude Code hook messages (Core)`.

---

### Task 8: The hook helper, the socket, held questions and permissions

**Files:**
- Create: `Sources/singularity-hook/main.swift`, `Sources/Singularity/Inbox/HookSocket.swift`
- Modify: `Package.swift` (product + `executableTarget(name: "singularity-hook", dependencies: ["SingularityCore"])` only if it uses `ClaudeHook.wireLine`; otherwise no dependencies, like `singularity-mcp`), `scripts/build-app.sh`, `scripts/release.sh` (build, copy to `Contents/MacOS/`, codesign, exactly as `singularity-mcp`), `Sources/Singularity/Terminal/TerminalSession.swift` (env), `Sources/SingularityCore/Terminal/HerdrCore.swift` (`runArguments` passes both variables through `/usr/bin/env`; update its test in `TerminalTests.swift`), `Sources/Singularity/Inbox/InboxCenter.swift`, `InboxViews.swift`, `Sources/SingularityCore/Persistence/Paths.swift` (`hookSocket`), `AppState.swift` (start/stop the listener next to the MCP one)
- Test: `Tests/SingularityAppTests/InboxPanelTests.swift` (suite `HeldRequestTests`), `Tests/SingularityCoreTests/TerminalTests.swift`

**Interfaces:**
- Consumes: `ClaudeHook`, `Inbox.hold/remove/demote/wentToTerminal`, `MCPSocketListener` (reuse as is: same folder/socket permissions and same-uid check).
- Produces:

```swift
/// One accepted helper connection: read one line, hand it over, later write the reply and close.
final class HookConnection: @unchecked Sendable {
    func reply(_ data: Data)                 // writes data, closes; safe to call once, later calls ignored
    var onClosedByPeer: (@Sendable () -> Void)?   // helper went away (Claude Code quit / interrupted)
}
extension InboxCenter {
    /// Entry point for the socket. Decides at once (no decision / Stop) or holds.
    func hookArrived(tabID: UUID, hookInput: Data, connection: HookConnection)
    func answerQuestion(_ id: UUID, answers: [String: [String]])
    func decidePermission(_ id: UUID, allow: Bool)
    var holdLimit: Duration { get set }      // default from Task 0 (aim .seconds(3300))
}
```

- Helper (`singularity-hook`), in this order: read `SINGULARITY_TAB` and `SINGULARITY_HOOK_SOCKET`; either missing → `exit(0)`. Connect (Unix socket; `connect` fails at once when nobody listens) → on failure `exit(0)`. Read all of stdin, send `wireLine`, `shutdown(SHUT_WR)`. Read the reply until EOF, write it to stdout, `exit(0)`. Ignore `SIGPIPE`. Never start the app. No output on stderr.
- `hookArrived`:
  - unknown tab → `connection.reply(ClaudeHook.noDecision)`.
  - `.stop(text)` → `inbox.noteLastMessage`, reply `noDecision` at once.
  - `.ignored` → reply `noDecision`.
  - `.question` / `.permission` → `inbox.hold(…)`; `nil` (looked at) → reply `noDecision`; else keep `connection` and `toolInput` by entry id, start the hold-limit timer, `onArrival(entry)`.
  - `connection.onClosedByPeer` → remove the entry.
- `answerQuestion` → `reply(ClaudeHook.answerReply(…))`, remove entry. `decidePermission` → `reply(permissionReply)`, remove.
- `wentToTerminal` / `tabClosed` (already exist): reply `noDecision` to each returned held entry. Hold limit → `reply(noDecision)` + `inbox.demote(id)`.
- App quitting (`applicationWillTerminate`, next to `terminals.tearDownAll()`): reply `noDecision` to every held connection.
- `TerminalSession.environment`: add `SINGULARITY_TAB = tabID.uuidString` and `SINGULARITY_HOOK_SOCKET = Paths…hookSocket.path` (the function becomes non-static or takes them as parameters).
- Cards:
  - `.question`: each question's text; options as buttons. Exactly one single-choice question → clicking an option calls `answerQuestion` at once. Otherwise options toggle (single-choice questions behave as radio groups) and a "Send" button (enabled when every question has a choice) answers. "Other…" = `goTo(entry)`.
  - `.permission`: "Wants to use <tool>", the input in the monospaced box, Allow / Deny.

- [ ] **Step 1: Write the failing tests** (`HeldRequestTests`; use a fake `HookConnection` subclass or a protocol `HookReplying` so tests capture replies without a socket):
  - `questionFromAnotherSpaceIsHeldAndAnswered`: `hookArrived` with the Task 7 question JSON → one `.question` entry, no reply yet; `answerQuestion(id, ["Which database?": ["SQLite"]])` → reply decodes to `answers == ["Which database?": "SQLite"]`; entry gone.
  - `questionForTheTabOnScreenIsNotHeld`: tab selected, app active → reply is empty at once, no entry.
  - `goingToTheTerminalHandsItBack`: held → `state.showTab(…)` → empty reply, entry gone.
  - `holdLimitHandsItBackAndLeavesAWaitingEntry`: `holdLimit = .milliseconds(200)` → after 400 ms: empty reply, `visible.first?.kind == .waiting(.question)`.
  - `peerClosingRemovesTheEntry`.
  - `permissionAllowAndDeny`.
  - `stopSetsTheDoneMessage`.
  - `unknownTabGetsNoDecision`.
  - `twoPermissionsFromOneTabAreTwoEntries`.
  - Core, `TerminalTests`: `HerdrCore.runArguments` contains `SINGULARITY_TAB=<id>` and `SINGULARITY_HOOK_SOCKET=<path>`.
- [ ] **Step 2:** `swift test --filter HeldRequestTests` → FAIL.
- [ ] **Step 3:** Implement helper, socket, center methods, cards, env, scripts.
- [ ] **Step 4:** `scripts/test.sh` green.
- [ ] **Step 5:** Full bundle to `/private/tmp/sg-app`, run with `SINGULARITY_HOME=/private/tmp/sg-test`. In a scratch project, a project-level `.claude/settings.json` with the three hooks pointing at `/private/tmp/sg-app/Singularity.app/Contents/MacOS/singularity-hook` (timeout from Task 0). In a test-copy terminal run `claude` there and check: question answered from another Space (one question, several, multi-select); same question with the terminal in view appears in the terminal at once; "Go to terminal" and "Other…" hand it back; permission Allow and Deny. Quitting the test copy while a question is held: with the built-in terminal the shell dies with the app, so check this one with herdr-core switched on (`HC_SESSION=sg-inbox-test`): after the quit, `hc attach` to the shell from Terminal.app shows Claude Code's normal prompt, not a stuck session.
- [ ] **Step 6: Review Focus 1.** With the same scratch project: run `claude` in Terminal.app (no `SINGULARITY_TAB`) and in a test-copy terminal with the test copy's listener stopped; both must behave as without hooks. And: `echo '{}' | env -u SINGULARITY_TAB /private/tmp/sg-app/Singularity.app/Contents/MacOS/singularity-hook; echo "exit=$?"` → prints only `exit=0`, in well under 100 ms (`time`).
- [ ] **Step 7:** Commit `Inbox: singularity-hook helper, held questions and permission requests`.

---

### Task 9: Core — the settings.json edit

**Before this task:** check that the branch you work on contains the onboarding work (`AgentConnect`, `AgentConnector`, `AgentConnectRows`). It was merged into `main` on 2026-11-12 and this plan was rebased onto it, so it should. If those files are missing, stop here and tell the owner; Tasks 0–8 are complete and usable with hooks installed by hand.

**Files:**
- Create: `Sources/SingularityCore/Inbox/ClaudeHookSettings.swift`
- Test: `Tests/SingularityCoreTests/ClaudeHookSettingsTests.swift`

**Interfaces (Produces):**

```swift
public enum ClaudeHookSettings {
    public enum Status: Equatable, Sendable {
        case notInstalled
        case installed
        case otherCopy(String)     // our hooks, pointing at another helper path
        case unreadable            // not JSON, or `hooks` has a shape we don't understand
    }
    public struct Unreadable: Error {}
    public static let helperName = "singularity-hook"
    public static func file(home: URL) -> URL      // ~/.claude/settings.json

    /// `settingsText` nil = no file.
    public static func status(settingsText: String?, helper: String) -> Status
    /// Adds (or repoints) our three entries; everything else is kept. Throws Unreadable and
    /// returns nothing when the text can't be understood. Output: prettyPrinted, sortedKeys,
    /// withoutEscapingSlashes, trailing newline.
    public static func install(settingsText: String?, helper: String, timeoutSeconds: Int) throws -> String
    /// Removes our entries (any helper path); drops matcher groups, event arrays and the
    /// `hooks` object when they become empty. No hooks of ours → the text is returned unchanged.
    public static func remove(settingsText: String) throws -> String
}
```

- Our entries, as written by `install` (command = `AgentConnect.shellQuote(helper)`):

```json
"hooks": {
  "PreToolUse":        [{ "matcher": "AskUserQuestion", "hooks": [{ "type": "command", "command": "'<helper>'", "timeout": <timeoutSeconds> }] }],
  "PermissionRequest": [{ "hooks": [{ "type": "command", "command": "'<helper>'", "timeout": <timeoutSeconds> }] }],
  "Stop":              [{ "hooks": [{ "type": "command", "command": "'<helper>'", "timeout": 10 }] }]
}
```

- "Ours" = a hook object with `type == "command"` whose command, after removing quotes, has last path component `singularity-hook`. `installed` needs all three present with this helper path; any of ours with another path → `otherCopy(path)`; some but not all → `notInstalled` (install repairs it).

- [ ] **Step 1: Write the failing tests:**
  - `installIntoNoFile`: `install(settingsText: nil, …)` → parses; the three entries exist; `status == .installed`.
  - `installKeepsEverythingElse`: input with `"model"`, `"permissions"`, an existing `PreToolUse` group with matcher `Bash` and another tool's `Stop` hook → all still present and equal after install; ours added as separate groups.
  - `installTwiceIsTheSame`: `install(install(x)) == install(x)`.
  - `installRepointsAnotherCopy`: installed with `/A/singularity-hook`, status for `/B/…` is `.otherCopy("/A/singularity-hook")`; install with `/B/…` → `.installed`, no `/A/` left.
  - `removeRestoresTheRest`: `remove(install(x))` parses equal to `x` (compare as `NSDictionary`), for `x` with and without other hooks; `remove` of text without our hooks returns it byte-for-byte.
  - `unreadableIsRefused`: `"{ // comment\n}"`, `"[]"`, `{"hooks": []}`, `{"hooks": {"Stop": {}}}` → `status == .unreadable`, `install` and `remove` throw `Unreadable`.
  - `pathWithSpacesAndQuotes`: helper `/Users/o'neil/My Apps/Singularity.app/Contents/MacOS/singularity-hook` → install then status `.installed`.
  - `partialInstallIsNotInstalled`.
- [ ] **Step 2:** `swift test --filter ClaudeHookSettingsTests` → FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** PASS.
- [ ] **Step 5:** Commit `Inbox: adding and removing the hook in Claude Code's settings (Core)`.

---

### Task 10: Settings → Agents, and the docs

**Files:**
- Modify: `Sources/Singularity/Agent/AgentConnectRows.swift` (or `SettingsView.swift`, wherever the Claude Code row lives after the rebase), `Sources/Singularity/Agent/AgentConnector.swift` (or a small new `Sources/Singularity/Inbox/HookInstaller.swift` if that file is about `mcp add` only), `CLAUDE.md`, `IDEAS.md` (remove the "Agent inbox" entry under "Approved: projects"), the spec (status line → "built on …", plus an "As built" section for anything that ended up different)

**Interfaces:**
- Consumes: `ClaudeHookSettings`, `AgentConnect.isTranslocated`, the helper path next to the running binary (`Bundle.main.executableURL` sibling `singularity-hook`; missing in the bare binary → row says "needs the app bundle").
- Produces:

```swift
@MainActor final class HookInstaller {
    init(settingsFile: URL = ClaudeHookSettings.file(home: FileManager.default.homeDirectoryForCurrentUser))
    func status() -> ClaudeHookSettings.Status
    func install() throws      // read → ClaudeHookSettings.install → atomic write; creates ~/.claude/ if missing
    func remove() throws
}
```

- Row under Claude Code in Settings → Agents: title "Show questions in the inbox"; caption "Adds a hook to ~/.claude/settings.json so Claude Code's questions and permission requests can be answered in Singularity's inbox. Rewriting the file may reorder its keys."; button by status: Install / Remove / Update (other copy: caption shows the other path) / none when translocated; `unreadable` → "~/.claude/settings.json couldn't be read as JSON; it was left alone." Errors from install/remove are shown in the row, not swallowed.
- The write happens **only** from these buttons. Timeout value = Task 0's `hookTimeoutSeconds`.

- [ ] **Step 1: Failing test** (`InboxPanelTests.swift`, suite `HookInstallerTests`): `HookInstaller(settingsFile: <temp file>)` — `install()` on a missing file creates it and `status() == .installed`; `remove()` leaves `{}`-equivalent content or other keys intact; a file containing `not json` → `install()` throws and the file's bytes are unchanged.
- [ ] **Step 2:** FAIL → **Step 3:** implement installer and row → **Step 4:** `scripts/test.sh` green.
- [ ] **Step 5:** By hand in the test copy, with `HOME` unchanged but the installer pointed at a temp file through a debug environment variable `SINGULARITY_CLAUDE_SETTINGS` (read only in `HookInstaller.init`'s default; document it in CLAUDE.md next to `SINGULARITY_HOME`): Install, Remove, Update states. Do **not** press Install against the owner's real file; the owner does that himself in his own copy.
- [ ] **Step 6:** CLAUDE.md: add `Inbox/` to both architecture lists and `singularity-hook` beside `singularity-mcp`; a "Agent inbox" bullet under Key decisions (levels 1 and 2; the hook socket and the two env vars; the looked-at vs went-to rule; approvals go through the inbox, no sheet; nothing saved; the `settings.json` exception to "config files are only read"; the bare binary has no notifications); a scope-change line ("agent inbox is in v1; not orchestration"); update the Approvals bullet (sheet → inbox entry) and the test description for `Tests/SingularityAppTests`.
- [ ] **Step 7:** Commit `Inbox: Install button in Settings → Agents; CLAUDE.md`.
- [ ] **Step 8:** Report to the owner what he has to do by hand: press Install in his own copy, allow notifications when macOS asks, and try one real question from another Space.
