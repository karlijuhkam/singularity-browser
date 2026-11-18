# More than one browser window: implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Any number of equal browser windows, each with its own Space, selected tab and hidden sidebar, the same Space allowed in two windows, a tab on screen in one window at most.

**Architecture:** "The front window is live." `AppState.selectedSpaceID` and each `Space.selectedTabID` keep meaning what they mean today, but for the *front* browser window only, so the ~60 existing callers stay as they are. Every other window keeps a `BrowserWindowState` record (its Space, its selected tab per Space, its sidebar). When another browser window becomes key, the front's live selection is written into its record and the new window's record is loaded into the live fields ("swap"). After every change of the model, a pure Core rule (`WindowLayout.reconcile`) fixes the other windows' records so none shows a tab the front window (or an earlier window) shows, a closed tab, or a deleted Space. Views take the window's id from the SwiftUI environment and ask `AppState.shownSpace(in:)` / `shownTabID(in:space:)`, which for the front window answer the live fields.

**Tech Stack:** Swift, SwiftUI `WindowGroup(id:for:)` with `UUID` values, AppKit `NSWindow` notifications, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-11-18-multi-window-design.md`

## Global Constraints

- macOS 14+; no new dependency.
- One window loads exactly as today; a `state.json` without `windows` becomes one window.
- `state.json` keeps writing `selectedSpaceID`, and `settings.json` keeps `sidebarHidden`, as the front window's values (downgrade to 0.17.0).
- No app test makes a window key (CLAUDE.md); model logic is tested on `AppState` without windows.
- Shortcuts: New Window ⌘N, New Note ⌃⌘N, Today's Note ⌥⌘N, New Private Window ⇧⌘N, Close Window ⇧⌘W.
- An automatic selection (artifact page's `singularity.open`) goes to the window showing its origin tab; no such window = added, selected nowhere.

## Review Focus

1. A tab clicked in window 1 that window 2 shows: window 2 must move to a free neighbour, never show the same web view (the view would jump windows).
2. Closing the front window: the next key browser window becomes front and the closed record is removed; closing the last one keeps its record (the app quits).
3. Deleting a Space shown only in a background window: that window moves to `spaces.first`.
4. Launch with records whose Space was deleted on disk, or whose frame is off every screen.
5. Switching Space in the front window to a Space whose last-selected tab another window shows: the front gets a free tab (or none), and does not steal.

---

### Task 1: Core window model and rules

**Files:**
- Create: `Sources/SingularityCore/Model/BrowserWindow.swift`
- Modify: `Sources/SingularityCore/Persistence/SpaceStore.swift` (`AppStateFile`)
- Test: `Tests/SingularityCoreTests/BrowserWindowTests.swift`

**Interfaces (Produces):**
- `public struct WindowFrame: Codable, Equatable, Sendable { x, y, width, height: Double }`
- `public struct BrowserWindowState: Codable, Equatable, Identifiable, Sendable { id: UUID; spaceID: UUID?; selectedTabIDs: [UUID: UUID]; sidebarHidden: Bool; frame: WindowFrame? }` (tolerant decoding: missing fields default)
- `public enum WindowLayout`:
  - `static func shownTabIDs(in space: Space, selected: UUID?) -> Set<UUID>`: the selected tab and every tab of its split; empty when `selected` is nil or not in the Space.
  - `static func freeTab(in space: Space, preferring: UUID?, taken: Set<UUID>) -> UUID?`: `preferring` when it exists and neither it nor its split partners are in `taken`; else the first tab after it in `tabsInSidebarOrder` (then before it, nearest first) whose shown set is disjoint from `taken`; nil when none.
  - `static func reconcile(_ windows: [BrowserWindowState], frontID: UUID?, frontSpaceID: UUID?, frontSelected: UUID?, spaces: [Space]) -> [BrowserWindowState]`: the front record is left untouched; for every other window in order: a missing Space becomes `spaces.first?.id`; its selection in its Space goes through `freeTab(preferring: current, taken:)` with `taken` = the front's shown set plus every earlier window's shown set (same Space only); entries of `selectedTabIDs` for deleted Spaces or tabs are dropped.
- `AppStateFile` gains `windows: [BrowserWindowState]` (default `[]`) and `frontWindowID: UUID?`, decoded with `decodeIfPresent`.

- [ ] Step 1: tests: `freeTabPrefersCurrent`, `freeTabSkipsTakenAndSplitPartners`, `freeTabNilWhenAllTaken`, `reconcileMovesWindowOffFrontTab`, `reconcileKeepsFrontUntouched`, `reconcileDeletedSpaceGoesToFirst`, `reconcileClosedTabPicksNeighbour`, `reconcileTwoBackgroundWindowsDontShare`, `appStateFileWithoutWindowsDecodes`, `appStateFileRoundTripsWindows`.
- [ ] Step 2: run `source scripts/env.sh && swift test --filter BrowserWindowTests`, expect compile failure.
- [ ] Step 3: implement.
- [ ] Step 4: tests pass.
- [ ] Step 5: commit.

### Task 2: AppState keeps windows

**Files:**
- Create: `Sources/Singularity/App/AppState+Windows.swift`
- Modify: `Sources/Singularity/App/AppState.swift` (load, save, selectSpace, deleteSpace, closeTab paths via `mutateSpace`, openInNewTab, toggleSidebar, sidebarIsOffScreen, applyWindowButtons, isTabOnScreen, mainWindow)
- Test: `Tests/SingularityAppTests/MultiWindowTests.swift` (nested in `AppTests`, `TestAppState.make`, no NSWindow)

**Interfaces (Produces):**
- `private(set) var windows: [BrowserWindowState]`, `private(set) var frontWindowID: UUID?`
- `func shownSpace(in windowID: UUID) -> Space?`, `func shownTabID(in windowID: UUID, space: Space) -> UUID?`, `func shownTab(in windowID: UUID) -> BrowserTab?`
- `func sidebarHidden(in windowID: UUID) -> Bool`, `func toggleSidebar()` acts on the front.
- `func activateWindow(_ id: UUID)`: the swap (no-op when already front). Writes the live fields directly; never through `selectSpace`/`selectTab` (no inbox `wentToTerminal`, no `previousTabBySpace`/`activeTerminalBySpace` change); then `loadSelectedTab`, `plugins.frontDidChange`, `extensions.selectionChanged`.
- `@discardableResult func addWindow() -> UUID`: new record on the front's Space, selection `freeTab(preferring: space.selectedTabID, taken: every window's shown set)`, sidebar shown; appended, not made front (it becomes front when its NSWindow becomes key).
- `func windowClosed(_ id: UUID)`: removes the record unless it is the last; when it was front, activates the next record.
- `func claimWindow(_ requested: UUID?) -> UUID`: the window a new SwiftUI scene shows: `requested` if it is a record not yet claimed, else the first unclaimed record, else `addWindow()`. `func unclaimedWindowIDs() -> [UUID]`.
- `func windowIDShowing(_ tabID: UUID) -> UUID?`; `func isTabShownInAnyWindow(_:)`; `func isTabSelectedInAnyWindow(_:)`.
- `enum TabTarget { case front, origin(UUID), nowhere }`; `openInNewTab(_ url:, spaceID:, target: TabTarget = .front)`. `.origin(tab)`: the window showing that tab gets the new tab selected (front: as today; background: its record); no window shows it = appended only. Callers: `ArtifactBridge` `.origin(its tab)`; extensions' own `tabs.create`/activate (`ExtensionCenter` 366/700/715, `ExtensionAdapters` 89-92) `.origin` of the extension's tab when known, else `.nowhere`; palette, Settings, little windows `.front`. `openArtifact` stays a user action (front).
- `selectSpace`: after switching, if the Space's selected tab is shown in another window, select `freeTab` instead (no stealing).
- `reconcileWindows()` is called explicitly at the end of `mutateSpace`, `selectSpace`, `deleteSpace`, `activateWindow`, `windowClosed` (same main-actor turn as the change; no `didSet`). It applies `WindowLayout.reconcile` and marks `state.json` dirty when records changed.
- Save: `AppStateFile(spaceOrder:, selectedSpaceID:, windows: records with the front's live values written in, frontWindowID:)`; `settings.sidebarHidden` follows the front window on every toggle and swap.
- `loadSelectedTab` loads the shown tabs of *every* window (and starts their Spaces' artifact servers), not just the front's.
- Load: records from the file; none → one record from `selectedSpaceID`, the Spaces' `selectedTabID`s and `settings.sidebarHidden`; front = file's `frontWindowID` if present else first; front record loaded into the live fields.

- [ ] Step 1: tests: `oneWindowFromOldStateFile`, `newWindowShowsFreeTab`, `swapKeepsEachWindowsSelection`, `selectingTabShownElsewhereMovesOtherWindow`, `switchingSpaceDoesNotSteal`, `closingTabInFrontFixesBackgroundWindow`, `deletingSpaceMovesBackgroundWindow`, `closingFrontWindowActivatesNext`, `closingLastWindowKeepsRecord`, `sidebarHiddenIsPerWindow`, `openFromArtifactGoesToOriginWindow`, `openFromArtifactWithoutWindowSelectsNothing`, `windowsSurviveSaveAndLoad`, `swapDoesNotClearInboxEntries`, `clickInBackgroundWindowSelectsThere` (activate then `focusPane`: window 1 unchanged), `backgroundWindowTabsAreLoaded`, `paletteNewTabStillSelects`.
- [ ] Step 2: run, expect failure. Step 3: implement. Step 4: run `scripts/test.sh`-equivalent filter, pass. Step 5: commit.

### Task 3a: Scene, claim, restore

**Files:** `SingularityApp.swift`, `MainView.swift`, new `App/BrowserWindowReader.swift`.
- `WindowGroup(id: "browser", for: UUID.self)`; root view calls `claimWindow($id.wrappedValue)` once, stores the result in `@State`, writes it back to the binding, puts it in `EnvironmentValues.browserWindowID`. A restored value no record has, while every record is claimed: the scene closes its window (never `addWindow`, or the count grows each launch).
- The first claimed window opens every `unclaimedWindowIDs()` with `openWindow(id: "browser", value:)`.
- `BrowserWindowReader`: registers the NSWindow (`registerWindow(_:for:)`, weak), sets `isRestorable = false`, applies the stored frame once if it intersects a screen's visible frame, observes `didBecomeKey` → `activateWindow`, `willClose` → `windowClosed` (not while the app terminates), `didMove`/`didResize` → frame into the record; title = Space name.
- `mainWindow` becomes computed: the front record's NSWindow. `applyWindowButtons` loops every registered window with its own hidden state. `SidebarPeekController` works on the front window only (a hidden sidebar in a background window slides out after it was clicked to the front).
- One app-wide `leftMouseDown` local monitor installed before `PaneContainerView.installFocusMonitor`: a click in a browser window that isn't front calls `activateWindow` first.
- Check: bundle in `/private/tmp/sg-app`, `SINGULARITY_HOME`, hand-written `state.json` with 2 windows; start, quit (SIGTERM), start again: `CGWindowListCopyWindowInfo` shows exactly 2 browser windows both times. Never activate or send input.

### Task 3b: Views read their window; modals in one window

**Files:** `MainView.swift`, `Sidebar/*`, `Split/SplitViews.swift`, `Home/HomeView.swift`, `Palette/CommandPaletteView.swift`.
- `ContentArea`, `SidebarView` and children, split views and home read `shownSpace(in:)`/`shownTabID(in:space:)`/`sidebarHidden(in:)`; the Space tint too.
- Sheets (`spaceEditor`, `nameRequest`, `isImportingFromArc`, `extensions.pending`, the install alert) and the palette overlay are attached only in the window that is front (`windowID == frontWindowID`).
- Hard check: `grep -rn 'state\.selectedSpace\|state\.selectedTab\b\|settings\.sidebarHidden\|state\.palette' Sources/Singularity/{Sidebar,Split,Home} Sources/Singularity/App/MainView.swift` returns only window-scoped or front-gated reads.

### Task 3c: Commands, panel, welcome, agents

**Files:** `Commands.swift`, `AppState.swift`, `Notes` docs, `ArtifactBridge.swift`, `AgentToolbox.swift`, `Extensions/*`.
- New Window ⌘N (`state.newWindow()` → `addWindow` + `openWindow`), New Note ⌃⌘N, Close Window ⇧⌘W (front browser window `performClose`; over the welcome flow closes the flow), ⌘W on a window showing no tab closes it while another browser window is open. Palette: "New Window".
- Plugin panel only in `panelWindowID` (set to the front by ⌃⌘J / show; default the front); welcome flow only in `onboardingWindowID` (the front when opened); `welcomeCoversWindow` = covers the front.
- `list_tabs` flags: `selected` = selected in any window, `visible` = shown in any window.

### Task 4: Docs, review, ship

- [ ] CLAUDE.md: scope change line and a "Windows" key-decision paragraph; spec "As built"; notes docs/menus for ⌃⌘N; IDEAS.
- [ ] `scripts/test.sh` green; whole-branch review by a fresh reviewer; fix.
- [ ] Merge into `main` (check `git worktree list`, fetch), `scripts/release.sh <next> --yes`.
