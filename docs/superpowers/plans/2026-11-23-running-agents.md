# Running Agents Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The inbox panel lists every running agent (name + Space, click goes there) and each Space circle in the rail shows how many agents run in it, accent while one works, grey when all idle.

**Architecture:** Pure rules in Core (`RunningAgents`: which program names count, the rows in order, per-Space counts), fed by the app with each terminal's live foreground program (`AppState.terminalHandle(_:)?.foregroundProgram`) and `InboxCenter.board`. Two views read `AppState.runningAgents`: a "Running" section in the inbox list and a second badge on `SpaceDot`.

**Tech Stack:** Swift, SwiftUI, Swift Testing. No new dependencies.

**Spec:** `docs/superpowers/specs/2026-11-23-running-agents-design.md`

## Global Constraints

- Nothing is saved; nothing is logged with agent text; tab titles are untrusted: `InboxText.clean` and `Text(verbatim:)`.
- Agent names: `claude`, `codex`, plus the first word of each launcher command in `AppState.launchers` (the cleaned list).
- No test starts a shell: terminals are fakes via `AppState.terminalHandleOverride`. Never make a window key in an app test. App suites nest in `AppTests` (see AppTests.swift).
- Build/test only after `source scripts/env.sh`; run `scripts/test.sh` before finishing.
- Never reading a terminal starts one: use `terminalHandle(_:)` (existing sessions only), never `terminals.session(for:in:)`.

## Review Focus

- A Node-run agent shows as `codex.js` (ProcessInspector names the script): must still count → Task 1 test `scriptExtensionIsIgnored`.
- A launcher command with env assignments or a path (`FOO=1 /opt/bin/aider --x`): first word that isn't `NAME=value`, its last path component → Task 1 test `launcherFirstWord`.
- A terminal in a Space with a tab that was closed or a herdr tab with no session: not listed, no crash → Task 1 test `noProgramNoRow` / Task 2 test.
- The shell back at the prompt (`foregroundProgram` nil) after an agent exits: row disappears at once → Task 2 test `exitedAgentLeaves`.
- Case: `Claude` vs `claude` (program names compared lower-cased) → Task 1 test `caseInsensitive`.

---

### Task 1: Core rules — `RunningAgents`

**Files:**
- Create: `Sources/SingularityCore/Inbox/RunningAgents.swift`
- Test: `Tests/SingularityCoreTests/RunningAgentsTests.swift`

**Interfaces:**
- Produces:
  - `public enum RunningAgents`
  - `static func agentNames(launcherCommands: [String]) -> Set<String>` — always contains `"claude"`, `"codex"`; for each command the first whitespace-separated word that does not match `^[A-Za-z_][A-Za-z0-9_]*=`, its `lastPathComponent`, lower-cased; empty commands add nothing.
  - `static func isAgent(program: String?, names: Set<String>) -> Bool` — nil/empty → false; lower-cased, with a path extension removed (`codex.js` → `codex`), then `names.contains`. Also true when the name with its extension is in the set.
  - `public struct Row: Equatable, Sendable, Identifiable { public var tabID: UUID; public var spaceID: UUID; public var state: TerminalBoard.State; public var id: UUID { tabID } }`
  - `static func rows(spaces: [Space], names: Set<String>, program: (UUID) -> String?, state: (UUID) -> TerminalBoard.State?) -> [Row]` — Spaces in the given order, within each `space.tabsInSidebarOrder.filter(\.isTerminal)`; a row when `isAgent(program(tab.id))`; `state` nil → `.unknown`.
  - `public struct SpaceCount: Equatable, Sendable { public var count: Int; public var anyWorking: Bool }`
  - `static func counts(_ rows: [Row]) -> [UUID: SpaceCount]` keyed by spaceID; Spaces with none are absent.

- [ ] **Step 1: Write the failing tests** (Swift Testing, `@Suite struct RunningAgentsTests`)
  - `defaultsAlwaysThere`: `agentNames(launcherCommands: [])` == `["claude", "codex"]`.
  - `launcherFirstWord`: commands `["claude --resume", "FOO=1 /opt/bin/Aider --x", "  ", "gemini"]` → contains `"aider"`, `"gemini"`, `"claude"`, `"codex"`, count 4.
  - `scriptExtensionIsIgnored`: `isAgent(program: "codex.js", names: agentNames([]))` true; `"vim"` false; nil false; `""` false.
  - `caseInsensitive`: `isAgent(program: "Claude", …)` true.
  - `noProgramNoRow` / ordering: two Spaces A, B (built like other Core tests build `Space` with terminal tabs; check `Tests/SingularityCoreTests/TabAttentionTests.swift` for a helper), A has terminals t1 (`claude`), t2 (`vim`), t3 (nil); B has t4 (`codex`); also a web tab. `rows(spaces: [B, A], …)` → `[t4, t1]` with spaceIDs B, A; state for t1 `.working`, t4 nil → `.unknown`.
  - `countsPerSpace`: rows A:(working, idle), B:(idle) → A `SpaceCount(count: 2, anyWorking: true)`, B `(1, false)`; a Space without rows absent.

- [ ] **Step 2: Run to see them fail**

Run: `source scripts/env.sh && swift test --filter RunningAgentsTests`
Expected: compile failure, `RunningAgents` not found.

- [ ] **Step 3: Implement `RunningAgents` as specified above.**

- [ ] **Step 4: Run again**

Run: `swift test --filter RunningAgentsTests` — Expected: all pass.

- [ ] **Step 5: Commit** — `git commit -m "Running agents: the rules (Core)"` (with the session line).

### Task 2: App — `AppState.runningAgents`, the rail badge

**Files:**
- Modify: `Sources/Singularity/App/AppState.swift` (near `launchers`, line ~1077)
- Modify: `Sources/Singularity/Sidebar/SpaceRail.swift` (`SpaceDot`)
- Modify: `Sources/Singularity/Inbox/InboxViews.swift` (add `RunningCountBadge` next to `InboxCountBadge`)
- Test: `Tests/SingularityAppTests/RunningAgentsStateTests.swift` (nested in `AppTests`, like `HomeTests.swift`, which already uses `terminalHandleOverride` with a fake handle — reuse its fake)

**Interfaces:**
- Consumes: Task 1's `RunningAgents.agentNames/rows/counts`, `Row`, `SpaceCount`.
- Produces: `var runningAgents: [RunningAgents.Row]` on `AppState` (computed; reads `inbox.boardRevision` first so views redraw on board changes, then `RunningAgents.rows(spaces: spaces, names: agentNames(launcherCommands: launchers.map(\.command)), program: { terminalHandle($0)?.foregroundProgram }, state: { inbox.board.row($0)?.state })`); `var runningAgentCounts: [UUID: RunningAgents.SpaceCount]`.
- Produces: `struct RunningCountBadge: View { let count: RunningAgents.SpaceCount? }` — nothing when nil; else a small capsule like `InboxCountBadge`'s size, digits `monospacedDigit`, filled `Color.accentColor` when `anyWorking`, else `Color.secondary.opacity(0.55)`, white text.

- [ ] **Step 1: Failing app tests**
  - `listsOnlyAgentsWithLiveSessions`: real `AppState` (`TestAppState.make(root: TestAppState.makeRoot())`), a Space with three terminal tabs; override hands fakes with `foregroundProgram` `"claude"`, `"npm"`, and nil handle for the third. `state.runningAgents.map(\.tabID)` == `[first]`; `runningAgentCounts[space.id]` == `SpaceCount(count: 1, anyWorking: false)`. `TestAppState.shutDown` at the end.
  - `exitedAgentLeaves`: set the fake's program to nil → `runningAgents` empty, counts empty.
  - `launcherAddsName`: settings with a launcher `aider --yes` (through `updateSettings`), fake program `"aider"` → listed.

- [ ] **Step 2: Run** `swift test --filter RunningAgentsStateTests` → fails to compile.

- [ ] **Step 3: Implement** the two properties and `RunningCountBadge`. In `SpaceRail`, pass `running: state.runningAgentCounts[space.id]` to `SpaceDot` (compute the dictionary once per body, outside `ForEach`), and add `.overlay(alignment: .bottomTrailing) { RunningCountBadge(count: running).offset(x: 2, y: 1).allowsHitTesting(false) }`. `.help` becomes `"\(space.name) · N agents running"` when count > 0 (`1 agent running` singular).

- [ ] **Step 4: Run** the tests → pass. Build the app (`swift build`) → no errors.

- [ ] **Step 5: Commit** — `"Running agents: AppState list and the rail count"`.

### Task 3: Inbox panel — the "Running" section

**Files:**
- Modify: `Sources/Singularity/Inbox/InboxViews.swift` (`InboxListView`, `InboxHeader`; new `InboxRunningSection`)
- Modify: `Sources/Singularity/Inbox/InboxPanel.swift` (`InboxPanelContent` stops passing `workingCount`)
- Modify: `Sources/Singularity/Inbox/InboxCenter.swift` (`goToTerminal`)
- Modify: `Sources/Singularity/Home/HomeSections.swift` (make `colour(_:)` reachable: move it to an `extension TerminalBoard.State { var dotColour: Color }` in InboxViews.swift and use it in both)
- Test: extend `Tests/SingularityAppTests/RunningAgentsStateTests.swift`

**Interfaces:**
- Consumes: `AppState.runningAgents` (Task 2).
- Produces: `func goToTerminal(tabID: UUID, spaceID: UUID)` on `InboxCenter`: `closePanel()`, `state?.showTab(tabID, in: spaceID)`, `wentToTerminal(tabID)`. `goTo(_:)` uses it for non-approval entries.

- [ ] **Step 1: Failing test** `runningRowGoesToTerminal`: two Spaces, an agent tab in the non-selected one; `state.inbox.goToTerminal(tabID:spaceID:)` → that Space is shown and the tab selected (assert the same way `HomeTests`/inbox tests check `showTab`), and an inbox entry for that tab (add one via a `.status` blocked signal through `state.inbox.terminalSignal`) is gone.

- [ ] **Step 2: Run** → fails (no `goToTerminal`).

- [ ] **Step 3: Implement.**
  - `goToTerminal` as above; `goTo` calls it.
  - `InboxRunningSection(rows:onGo:)`: header `Text("Running · \(rows.count)")` 11 pt semibold secondary, then one plain `Button` per row (non-focusable like `inboxCardLinkButton`: `.focusable(false)`), label `HStack`: `Circle().fill(row.state.dotColour.mapping .done/.idle/.unknown → .secondary)` 7 pt; `Text(verbatim: InboxText.clean(tab.displayTitle, limit: 80))` 12 pt, one line, tail truncation; `Spacer`; `Text(verbatim: [space.icon, space.name].compactMap{$0}.joined(separator: " "))` 11 pt secondary, one line. Rows whose tab or Space no longer exists are skipped. Hover highlight like the card link buttons.
  - `InboxListView`: cards as now; then `InboxRunningSection` when `runningAgents` is non-empty (with 6 pt divider spacing above when there are cards); the empty text becomes `"Nothing is running or waiting."`, shown only when both are empty.
  - `InboxHeader`: drop the "N more agents working" text and its `workingCount` parameter (the section now shows them). Leave `Inbox.workingCount` in Core if other code uses it; otherwise remove it with its tests.
  - Dot colours (spec): working = accent, waiting = orange, else grey.

- [ ] **Step 4: Run** `swift test --filter "RunningAgents|Inbox"` → pass; `swift build` clean.

- [ ] **Step 5: Docs + commit.** Add one bullet to CLAUDE.md under **Agent inbox**: running agents (rule: `RunningAgents` in Core; names = claude, codex, launcher first words; live sessions only; tmux not seen; inbox "Running" section; rail bottom-right count, accent while one works). Add `RunningAgents` to the Core `Inbox/` line of the Architecture tree. Commit `"Running agents: the inbox's Running section"`.

### Task 4: Full gate

- [ ] Run `scripts/test.sh` — Expected: all suites pass (if page-load tests fail, check the session isn't locked; see memory note on the WebKit wedge).
- [ ] `APP=/private/tmp/sg-app/Singularity.app scripts/build-app.sh` builds.
