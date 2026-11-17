# Space Home Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** ⌘T opens the selected Space's *home*, a native tab with the orb, a search/ask row and an overview of the Space's work; "Ask Assistant" hands typed text to the Assistant plugin.

**Architecture:** A new tab kind `TabKind.home` shown by a SwiftUI `HomeView`. Every rule (reuse, replace-in-place, section order, "new" marks, recent files, ask routing) is a pure function in Core (`SingularityCore/Home/`), tested. The row reuses `PaletteResults` with a new `PaletteMode.home(tabID:)`. A new plugin permission `ask` carries text app → plugin over `PluginWire.ask`.

**Tech Stack:** Swift 6 / SwiftUI / AppKit, Swift Testing, Bun tests for the Assistant plugin.

**Spec:** `docs/superpowers/specs/2026-11-17-space-home-design.md` (read it first; it wins over this plan where they differ).

## Global Constraints

- Build with `source scripts/env.sh` first (or the scripts). Never run `xcode-select -s`.
- App tests: nested in `AppTests`, `MainRunLoopGuard` first; real state via `TestAppState.make(root: TestAppState.makeRoot())`, stopped with `TestAppState.shutDown`. **Never make a window key. No test starts a shell or a `TerminalSession`** (use `AppState.terminalHandleOverride` fakes). No test runs the real `claude`.
- Untrusted text (terminal titles, agent messages, inbox text) goes through `InboxText.clean` and is drawn with `Text(verbatim:)`.
- The app writes nothing new to disk: the "new" marks and last-visit times live in memory only.
- `ask` text: at most 20 000 characters; never logged by the app.
- A Space not switched on for a plugin is unknown to it: `ask` carries `space: null` there (owner decision).
- Home tabs are hidden from agents (`isHiddenFromAgents`), like plugin tabs and notes.
- Do not loosen any existing plugin/agent rule from `CLAUDE.md`.
- Commit messages end with the line `Claude-Session: https://claude.ai/code/session_01X5WAkrrc3ZY1m8EKTBP6ca`.

## Review Focus

1. ⌘T pressed twice quickly, or ⌘T in a Space that already has a home: one home, selected (not two). Test in Task 1 (`HomeRules.reusableHome`) and Task 3 (`openHomeTwiceMakesOneTab`).
2. A home that is a pane of a split, then becomes a terminal/note: the new tab takes the pane, the split survives. Test in Task 1 (`replaceKeepsSplitPane`).
3. "New Terminal in…" picker cancelled from the home: the home stays as it was. Test in Task 4 (`cancelledPickerLeavesHome`).
4. Ask with the Assistant not ready (panel never opened): the text becomes a draft, never lost. Test in Task 6 (`askWhileNotReadyBecomesDraft`).
5. Ask from a Space not switched on for the plugin: the wire message has `space: null`, no slug or name anywhere. Test in Task 2 (`askSpaceIsNullWhenSpaceOff`) and Task 5.

---

### Task 1: Core — the home tab kind and `HomeRules`

**Files:**
- Modify: `Sources/SingularityCore/Model/BrowserTab.swift` (add `case home`, `static func home()`, `isHome`, include in `isHiddenFromAgents`, `untitledDisplayTitle` = "Home"; extend every exhaustive `switch` in Core: `url`, `workingDirectory`, `artifactPath`, `PluginReach.swift`)
- Create: `Sources/SingularityCore/Home/HomeRules.swift`
- Test: `Tests/SingularityCoreTests/HomeRulesTests.swift`

**Interfaces:**
- Produces:
  - `TabKind.home`; `BrowserTab.home() -> BrowserTab` (title "Home"); `BrowserTab.isHome: Bool`.
  - `HomeRules.reusableHome(in space: Space) -> UUID?` — the first tab with `isHome`.
  - `Space.replaceHome(_ homeID: UUID, with newTabID: UUID)` (in `HomeRules.swift` as an extension): moves the new tab to the home's index in `tabs`, gives it the home's `isPinned`/`folderID`, puts it into the home's split pane (`replaceInSplit`), removes the home, selects the new tab. No-op if either id is missing.
  - `HomeRules.tabToReplaceHome(before: Set<UUID>, after space: Space) -> UUID?` — the selected tab of `space` when it is not in `before` and is not a home; else nil.
  - `HomeRules.terminalOrder(_ rows: [(id: UUID, state: TerminalBoard.State, since: Date)]) -> [UUID]` — waiting, working, done, idle, unknown; within a state, newest `since` first.
  - `HomeRules.isNew(since: Date, lastLeft: Date?) -> Bool` — true when `lastLeft` is set and `since > lastLeft`.
  - `struct HomeRecentFile: Equatable, Sendable { enum Kind { case note, artifact, app }; let kind: Kind; let path: String; let modified: Date }`; `HomeRules.recent(_ files: [HomeRecentFile], limit: Int = 8) -> [HomeRecentFile]` — newest first, cut to `limit`.

- [ ] **Step 1: Write failing tests** in `HomeRulesTests.swift`: `homeKindRoundTripsThroughJSON` (encode/decode a `BrowserTab.home()`), `homeIsHiddenFromAgents`, `reusableHomeFindsTheExistingOne`, `replaceKeepsPositionFolderAndPin`, `replaceKeepsSplitPane` (home in a two-pane split, replaced by a new tab → split has the new tab, home gone), `tabToReplaceHomeIgnoresExistingTabs`, `terminalOrderIsWaitingWorkingDoneIdleUnknown`, `isNewOnlyAfterLastLeft` (nil → false), `recentIsNewestFirstAndCutAtEight`.
- [ ] **Step 2: Run** `source scripts/env.sh && swift test --filter HomeRulesTests` → fails to compile.
- [ ] **Step 3: Implement** the interfaces above; fix every exhaustive `switch` the compiler reports in Core.
- [ ] **Step 4: Run** the same command → PASS; then `swift build` (app target will show switches to fix in Task 3; leave those to Task 3 only if the app doesn't compile — otherwise add `.home` arms now with the obvious "nothing to load / not a web page" meaning, same as `.note`).
- [ ] **Step 5: Commit** "Space home: the home tab kind and its rules in Core".

### Task 2: Core + host — the `ask` plugin permission

**Files:**
- Modify: `Sources/SingularityCore/Plugins/PluginManifest.swift` (permission `ask: Bool`; refused without `panel`: "it asks to receive questions but has no panel"), `PluginApproval.swift` (widening, like `notifications` in commit 89bf73d), `Sources/Singularity/Plugins/PermissionDescriptions.swift` ("Receives what you type into a new tab's Ask row"), `PluginWire.swift` (`case ask(text: String, space: JSONValue)` app → host, encoded kind `"ask"`), `Resources/plugin-host/host.ts` (`singularity.onAsk(handler: ({ text, space }) => void)`; `space` is `{slug, name} | null`), `docs/plugins/AUTHORING.md` (one section).
- Create: `Sources/SingularityCore/Home/AskRules.swift`
- Test: `Tests/SingularityCoreTests/AskRulesTests.swift`, plus manifest/wire cases in the existing manifest and wire test files.

**Interfaces:**
- Produces:
  - `PluginManifest.Permissions.ask: Bool`.
  - `AskRules.maxLength = 20_000`.
  - `AskRules.target(toggle: String?, candidates: [(id: String, hasAsk: Bool, approved: Bool)]) -> String?` — `toggle` (the plugin ⌃⌘J would open) if it has ask and is approved, else the first approved candidate with ask, else nil.
  - `AskRules.spaceRef(_ space: Space, enabledSpaces: Set<UUID>) -> FrontTab.SpaceRef?` — the ref only when `space.id` is in `enabledSpaces`.
  - `AskRules.wireMessage(text: String, space: FrontTab.SpaceRef?) -> PluginWire?` — nil when text trimmed is empty or longer than `maxLength`; else `.ask(text:space:)` with `space` `.null` or `{slug,name}`.

- [ ] **Step 1: Failing tests**: `manifestRefusesAskWithoutPanel`, `askIsAWidening` (approval with ask = false, manifest now ask = true → needs re-approval), `wireEncodesAsk` (JSON has `"kind":"ask"`, `"text"`, `"space"`), `askSpaceIsNullWhenSpaceOff` (encoded JSON contains neither slug nor name), `askRefusesOverMaxLength`, `targetPrefersTheToggledPlugin`, `targetFallsBackToFirstApprovedWithAsk`.
- [ ] **Step 2: Run** `swift test --filter "AskRulesTests|PluginManifest|PluginWire"` → FAIL.
- [ ] **Step 3: Implement**; host.ts dispatches `ask` messages to the registered handler (drop when none).
- [ ] **Step 4: Run** → PASS; `Vendor/bun/bun test Tests/plugins` still passes if Bun is present.
- [ ] **Step 5: Commit** "Plugins: the ask permission (text from the home's Ask row)".

### Task 3: App — opening the home, tab plumbing, sidebar, empty Space

**Files:**
- Modify: `Sources/Singularity/App/AppState.swift` (`openHome()`, `loadTab`/`liveWebController` arms for `.home`), `Sources/Singularity/App/Commands.swift` (New Tab → `openHome()`; Open Location with no selected tab → `openHome()`; Command Palette unchanged), `Sources/Singularity/Sidebar/SidebarView.swift` (New Tab button and empty-area menu → `openHome()`), `Sources/Singularity/Sidebar/TabRow.swift` (icon `house`), `Sources/Singularity/Split/SplitViews.swift` / the tab content view (`.home` → `HomeView`), `Sources/Singularity/App/MainView.swift` (empty Space: `HomeView(tabID: nil)` instead of the bare orb), `Sources/Singularity/MCP/AgentToolbox.swift` (home filtered like `.note`), plus any other `.home` switch arm the compiler asks for.
- Create: `Sources/Singularity/Home/HomeView.swift` (placeholder body for now: orb + "Home" text; Task 4 fills it).
- Test: `Tests/SingularityAppTests/HomeTests.swift`

**Interfaces:**
- Consumes: Task 1.
- Produces: `AppState.openHome()` — closes the welcome flow (`closeWelcome()`), then selects `HomeRules.reusableHome` or appends `BrowserTab.home()` following New Tab's placement, selects it. `HomeView(tabID: UUID?)`.
  - `AppState.homeLeftAt: [UUID: Date]` (Space id → when its home was last on screen and then left), in memory.

- [ ] **Step 1: Failing tests**: `openHomeMakesAHomeTab`, `openHomeTwiceMakesOneTab`, `listTabsLeavesHomeOut` (agent toolbox), `frontNamesHomeKindOnly` (PluginReach: kind `"home"`, no title/url).
- [ ] **Step 2: Run** `swift test --filter HomeTests` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** → PASS; `swift build` clean.
- [ ] **Step 5: Commit** "Space home: ⌘T opens the Space's home tab".

### Task 4: App — the home's row and sections

**Files:**
- Modify: `Sources/Singularity/App/AppState.swift` (`PaletteMode.home(tabID: UUID)`; `homeNavigate(_ homeID: UUID, to url: URL)` — changes the tab's kind to `.web(url:)` in place, same id, then loads it), `Sources/Singularity/Palette/PaletteItem.swift` (`perform` for `.home`: `.openURL` → `homeNavigate`; `.selectTab` → `selectTab`; `.run` → snapshot tab ids, run, then `HomeRules.tabToReplaceHome` → `replaceHome`; `items(for:mode:)` treats `.home` like `.newTab`).
- Create: `Sources/Singularity/Home/HomeSearchField.swift` (the row: a text field with focus on appear, results under it from `PaletteResults.items(for:mode:.home(tabID:),state:)`, ↑/↓/Return like `CommandPaletteView`, Ask row last — Task 5 wires the action; ⌘Return picks it), `Sources/Singularity/Home/HomeSections.swift` (Waiting for you, Terminals, Projects, Recent), `Sources/Singularity/Home/HomeRecentLoader.swift` (reads `NoteFiles.list` and `ArtifactFiles.listPages` + app folders off the main actor, builds `[HomeRecentFile]`, refreshed on appear and on artifact-watcher / note-save changes).
- Modify: `Sources/Singularity/Home/HomeView.swift` (orb `OrbView(size: 96, stopsWhenIdle: true)` on top, row, sections; records `homeLeftAt` on disappear; a 60 s timer for relative times only while on screen).
- Test: `Tests/SingularityAppTests/HomeTests.swift`

**Interfaces:**
- Consumes: Tasks 1, 3; `InboxCenter.board` (`TerminalBoard.row(_:)`), the Core `Inbox` entries of the Space, `Space.projects`, `AppState.launchers`, `openTerminal(inFolder:)`/project terminal path (use the same path the project picker uses for a chosen project), `showTab(_:in:)`, the inbox panel's open-at-entry call.
- Rules from the spec: no answer buttons on the home (Go / Show only); sections hidden when empty; "Add a project…" opens Edit Space when there are no projects; untrusted text cleaned and `Text(verbatim:)`.

- [ ] **Step 1: Failing tests**: `addressTurnsHomeIntoWebTabWithSameID`, `newTerminalFromHomeTakesItsPlace` (fake terminal handle; the new terminal sits at the home's index and the home is gone), `cancelledPickerLeavesHome`, `selectingAnExistingTabLeavesHome`, `homeRowsShowCleanedTerminalTitles` (a title with control characters is cleaned), `newMarkAfterLeaving` (state changes after `homeLeftAt` → row marked).
- [ ] **Step 2: Run** `swift test --filter HomeTests` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** → PASS. Off-screen snapshot with `ImageRenderer` or the existing snapshot helper into the scratch folder for the visual check (not committed).
- [ ] **Step 5: Commit** "Space home: the row and the overview".

### Task 5: App — Ask Assistant

**Files:**
- Modify: `Sources/Singularity/Plugins/PluginManager.swift` (`sendAsk(_ text: String, from spaceID: UUID) -> Bool`: picks `AskRules.target`, builds `AskRules.wireMessage` with `AskRules.spaceRef` against that plugin's `enabledSpaces`, sends to its running background; false when none), `AppState` (`askAssistant(_ text: String)`: `sendAsk`, then shows that plugin's panel — moving its page from a tab to the panel if needed, as Move to Side Panel does — without changing the selected tab), `HomeSearchField.swift` (Ask row shown when the field isn't empty and `AskRules.target` is non-nil; title "Ask <panel title>"; clears the field after a send; over 20 000 characters shows "Too long to send (max 20 000 characters)." instead).
- Test: `Tests/SingularityAppTests/HomeAskTests.swift` with a fixture plugin that has `panel`, `background` and `ask` and records what it receives (pattern of the existing plugin fixtures; no `claude`).

**Interfaces:**
- Consumes: Task 2.

- [ ] **Step 1: Failing tests**: `askReachesThePluginWithSpace` (Space switched on → `{slug,name}`), `askFromSpaceOffHasNullSpace`, `askOpensPanelAndKeepsHome`, `askMovesTabPageToPanel`, `noAskRowWithoutAskPlugin`.
- [ ] **Step 2: Run** `swift test --filter HomeAskTests` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** "Space home: Ask Assistant hands the text to the plugin".

### Task 6: The Assistant plugin receives asks

**Files:**
- Modify: `Plugins/assistant/plugin.json` (`"ask": true`, version bump: minor), `Plugins/assistant/background.ts` (`singularity.onAsk`: if ready and no note held → same path as the page's `send`; else post a `draft` to the panel, appended to the input), `Plugins/assistant/panel.tsx` (handle `draft`: append to the input text and focus it), `Plugins/assistant/` front handling (kind `"home"`: no title/address; the tab-in-front block says "a new tab (home)").
- Test: `Tests/plugins/assistant*.test.ts` (existing fake `singularity`).

- [ ] **Step 1: Failing tests**: `askWhenReadySendsAMessage`, `askWhileNotReadyBecomesDraft`, `askWhileANoteIsHeldBecomesDraft`, `frontHomeHasNoTitle`.
- [ ] **Step 2: Run** `Vendor/bun/bun test Tests/plugins` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** "Assistant: takes asks from the home (send when ready, else a draft)".

### Task 7: Docs and the whole suite

**Files:**
- Modify: `CLAUDE.md` (a scope-change line dated 2026-11-17 for the home; architecture entries for `Home/` in Core and app; `TabKind` list gains `.home`; `ask` under the plugin permissions; the "Things to keep" bullets from the spec), `IDEAS.md` ("Summarise" button on the home under approved follow-ups, owner said later), the spec (an "As built" section listing any difference).
- [ ] **Step 1:** Run `scripts/test.sh` → all pass.
- [ ] **Step 2:** Commit "Documents: the Space home".
