# Agent door at Playwright parity: implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The MCP door reads and acts in iframes, sends trusted clicks and keys, turns dialogs and file choosers into waiting states, and gains `press_key`, `wait_for`, `handle_dialog`, `file_upload`, `hover`, `drag`; the Assistant knows all of it.

**Architecture:** `PageAgentScript` runs in every frame and introduces child frames to the app with a postMessage handshake (`WKScriptMessage.frameInfo` → `callAsyncJavaScript(in: frame)`). A new `AgentInput` sends `NSEvent`s straight to the `WKWebView` and swallows any key WebKit re-sends to the app. `WebTabController` holds an agent-caused dialog or file chooser as `pendingModal`. Core gets the new approval kinds and the key-name parser.

**Tech Stack:** Swift 6 / SwiftUI / AppKit / WebKit, MCP Swift SDK, Swift Testing; Bun tests for the plugin.

**Spec:** `docs/superpowers/specs/2026-11-20-playwright-parity-design.md`

## Global Constraints

- Tool names stay `<slug>.<tool>`; new ones: `press_key`, `wait_for`, `handle_dialog`, `file_upload`, `hover`, `drag`. No `evaluate`, `fill_form`, `select_option`, `resize`.
- Main-frame refs stay `[12]`; frame refs `[f<N>:<ref>]`; `ref` arguments accept integer or string.
- Frames: at most 50 per page, 2 levels below the main frame, 300 ms handshake wait.
- Held modal: at most 120 s; one per tab.
- `file_upload`: absolute paths, regular readable files, at most 20, asks in every policy except read-only, never "Allow on <site>".
- `press_key` refuses `Meta+V`, `Meta+C`, `Meta+X`, `Shift+Insert`.
- `wait_for`: poll 250 ms, at most 30 s.
- Never make a window key in a test; no test starts a shell; fixture servers are `/usr/bin/python3` on 127.0.0.1 (see `TitleFixtureServer`).
- Everything page-derived returned to an agent goes through `UntrustedContent.wrap`.
- Scratch files only under `mktemp -d` or the session scratchpad.
- Build/test: `source scripts/env.sh` first; never `xcode-select -s`.

## Review Focus

1. **A visible tab the owner is typing in elsewhere** (split pane: terminal focused, agent acts in the web pane): the owner's keystrokes must stay in the terminal; the agent's never reach it. Test: `keysNeverLeaveThePage` (Task 4) with a text field first responder in the same off-screen window.
2. **A dialog that opens from a script after the call ended** (setTimeout confirm in an agent tab): held, and the next call on that tab reports it; answered after 120 s if nobody does. Test: `aLateDialogIsReportedOnTheNextCall` (Task 5), with the hold limit overridable to 1 s in tests.
3. **An ad-heavy page** (many iframes, some never answering): `read_page` returns within ~1 s and lists unanswered frames as not readable. Test: `manyFramesStayBounded` (Task 3) with 60 iframes, 10 of them `about:blank` with `sandbox`.
4. **Refs after the page re-renders a frame** (frame navigates): old `f<N>:` refs give the "call read_page again" error, never act in the wrong document. Test: `aStaleFrameRefIsRefused` (Task 3).
5. **A plugin connection and a frame of a switched-off site**: the frame's content is not shown and can't be acted on. Test: `aSwitchedOffFrameIsHiddenFromAPlugin` (Task 3).

---

### Task 1: Core: approval kinds, key names, upload paths

**Files:**
- Modify: `Sources/SingularityCore/Agent/AgentPolicy.swift`
- Create: `Sources/SingularityCore/Agent/AgentKeys.swift`
- Create: `Sources/SingularityCore/Agent/UploadFiles.swift`
- Test: `Tests/SingularityCoreTests/AgentKeysTests.swift`, `Tests/SingularityCoreTests/UploadFilesTests.swift`, existing approval rules tests file (find with `grep -l AgentApprovalRules Tests/SingularityCoreTests`)

**Interfaces:**
- Produces: `AgentActionKind` new cases `pressKey, dialog, fileUpload, hover, waitFor, drag`; `isRead` true for `hover, waitFor`.
- Produces: `public struct KeyChord: Equatable, Sendable { public let key: String; public let characters: String; public let keyCode: UInt16; public let shift, control, option, command: Bool; public static func parse(_ text: String) throws -> KeyChord; public var isClipboard: Bool }` with `KeyChord.ParseError: Error, CustomStringConvertible`.
- Produces: `public enum UploadFiles { public static func check(_ paths: [String], multiple: Bool, fileManager: FileManager = .default) throws -> [URL] }` (resolved, absolute URLs), errors carry an agent-readable message.

- [ ] **Step 1: Tests.** Approval rules: `fileUploadAsksInAllowAll` (`decide(.fileUpload, .allowAll)` == `.ask(siteOrigin: nil)`), `fileUploadRefusedReadOnly`, `fileUploadNeverOffersTheSite` (under `.ask` with the page origin in `allowedOrigins` still `.ask(siteOrigin: nil)`), `hoverAndWaitForAreReads`, `pressKeyAndDialogAndDragFollowClick` (ask → `.ask(siteOrigin: page)`, allowed origin → `.allow`). Keys: `parse("Escape")` keyCode 53; `parse("Enter")` 36 chars "\r"; `parse("Control+k")` control, key "k", keyCode 40; `parse("Shift+Tab")` 48; `parse("ArrowDown")` 125 chars "\u{F701}"; `parse("a")` 0; `parse("é")` keyCode 0 chars "é"; `parse("F5")` 96; `parse("Meta+v").isClipboard`, `Meta+c`, `Meta+x`, `Shift+Insert`; `parse("")` and `parse("Control+")` and `parse("Hyper+a")` throw. Upload: temp dir with a file and a symlink to it, a folder, a missing path: relative path throws, folder throws, missing throws, symlink resolves to the file, 21 files throw, 2 files with `multiple: false` throw, empty list returns `[]`.
- [ ] **Step 2:** `swift test --filter "AgentKeysTests|UploadFilesTests|AgentApprovalRules"` fails to compile.
- [ ] **Step 3:** Implement. `decide`: `.fileUpload` handled like `.terminalSend` (before the policy switch). Key codes: macOS virtual key codes (kVK_*); function-key characters from `NSUpArrowFunctionKey` etc. (Core can't import AppKit: use the Unicode values `0xF700…`).
- [ ] **Step 4:** Tests pass.
- [ ] **Step 5:** Commit "Core: approval kinds, key names and upload paths for the new agent tools".

### Task 2: The bench as app tests (baseline)

**Files:**
- Create: `Tests/SingularityAppTests/Fixtures/bench/*.html`, `common.js`, `invoice.pdf` (the 23 bench files from the session scratchpad, plus `frames-many.html`, `nested.html`, `late-dialog.html` used later)
- Create: `Tests/SingularityAppTests/BenchServer.swift`: serves `Fixtures/bench` on two ports (`port` and `port + 1` style: start two python processes, each `http.server` bound 127.0.0.1 with `--directory`), `url(_ path:, other: Bool = false)`.
- Create: `Tests/SingularityAppTests/AgentParityTests.swift`: `extension AppTests { @MainActor @Suite(.serialized) struct AgentParityTests }` with a `Rig` (Space "Bench", slug `bench`, `agentsEnabled`, policy `.allowAll`, one tab on `index.html`), `call(_ tool:, _ args:) async -> String`, `read() async -> String`, `ref(of name: String) async -> String` (regex on the latest `read_page`), `result() async -> String` (the `RESULT:` line).

- [ ] **Step 1:** Tests that pass today: `selectByType`, `modalDialog`, `openShadowRoot`, `formFieldsAndSubmit`, `scrollBoxButton`, `spaRouteEventually` (polling read_page).
- [ ] **Step 2:** Run `swift test --filter AgentParityTests`: pass.
- [ ] **Step 3:** Commit "Tests: the agent bench pages as app tests".

### Task 3: Frames

**Files:**
- Modify: `Sources/Singularity/MCP/PageAgentScript.swift` (all frames; handshake; frame-aware snapshot/find/click/type/inspect)
- Create: `Sources/Singularity/MCP/AgentFrames.swift` (`AgentFrames`: per-controller registry and the merge of frame snapshots)
- Modify: `Sources/Singularity/Web/WebTabController.swift` (owns an `AgentFrames`; `callPageAgent(_:arguments:frame:)`), `Sources/Singularity/Web/WebViewRegistry.swift:142` (message handler in `PageAgentScript.world`), `Sources/Singularity/MCP/AgentToolbox.swift` (`Arguments.ref`, frame routing, per-site-off per frame)
- Test: `AgentParityTests` (+ `frames-many.html`, `nested.html`)

**Interfaces:**
- Produces: `struct AgentRef: Equatable { let frame: Int?; let local: Int; static func parse(_ value: Value) throws -> AgentRef; var text: String }` ("12", "f2:5").
- Produces: `WebTabController.agentFrames: AgentFrames`; `AgentFrames.frame(_ number: Int) -> WKFrameInfo?`, `AgentFrames.snapshot(controller:maxChars:allow:) async throws -> String`, `AgentFrames.find(controller:query:allow:) async throws -> String`, where `allow: (URL?) -> Bool` hides frames of switched-off sites.
- Produces: `WebTabController.callPageAgent(_ call: String, arguments: [String: Any], frame: WKFrameInfo? = nil) async throws -> String`.
- Produces in JS: `__singularityAgent.frames()` → `[{token, index, rect:[x,y,w,h], border:[l,t], src}]` (posts the handshake), and every existing function unchanged in shape.

- [ ] **Step 1: Tests.** `sameOriginFrameIsReadAndClicked` (iframe.html: type "XO" in the same-origin frame's Code, click Apply, frame text `frame got XO at <port>`), `crossOriginFrameIsReadAndClicked` (same, other port), `nestedFramesTwoDeep` (nested.html: leaf button), `manyFramesStayBounded` (frames-many.html, read_page < 2 s, contains "not readable"), `aStaleFrameRefIsRefused` (navigate the frame, old ref → "Call read_page again"), `aSwitchedOffFrameIsHiddenFromAPlugin` (follow `PluginDoorTests`' way of making a plugin caller; frame origin's site off → `iframe (switched off)`, acting on its ref refused), `pageScriptsNeverSeeTheHandshake` (inner page counts `message` events into its title; stays 0).
- [ ] **Step 2:** Fail.
- [ ] **Step 3:** Implement. Handshake nonce: a random string per `AgentFrames` instance passed in `frames()`'s arguments; child listener added at document start in capture phase, `stopImmediatePropagation()`, posts `{token}` to `webkit.messageHandlers.singularityAgentFrame` (registered with `add(_:contentWorld: PageAgentScript.world, name:)`); the handler maps token → `WKFrameInfo`, numbering frames per controller, reset on main-frame commit. Snapshot: main-frame snapshot emits a placeholder line `@@frame <index>@@` per iframe; native replaces it with the child's snapshot indented and refs rewritten `[f<N>:<r>]`; recursion depth 2.
- [ ] **Step 4:** Pass, plus the whole `AgentParityTests` and `PluginDoorTests`.
- [ ] **Step 5:** Commit "Agents read and act inside iframes".

### Task 4: Trusted clicks and keys; `press_key`; `type slowly`

**Files:**
- Create: `Sources/Singularity/MCP/AgentInput.swift`
- Modify: `PageAgentScript.swift` (`point(ref)` → centre + hit test, `focusAndClear(ref)`), `AgentToolbox.swift` (click → native, `double`; type `slowly`, `submit` via Enter; new `press_key`), `Sources/Singularity/Terminal/TerminalSession.swift:573` (ignore `AgentInput.isSynthetic(event)`)
- Test: `AgentParityTests`, new `AgentInputTests` (app test, off-screen window, never key)

**Interfaces:**
- Produces: `@MainActor enum AgentInput { static func click(_ webView: WKWebView, at cssPoint: CGPoint, double: Bool); static func press(_ chord: KeyChord, in webView: WKWebView); static func typeSlowly(_ text: String, in webView: WKWebView) async; static func isSynthetic(_ event: NSEvent) -> Bool; static func installSwallower() }`. `cssPoint` is in main-frame CSS px (frame offsets already added).
- Produces in JS: `point(ref)` → `{x, y, covered: string|null, visible: bool}` for the element's frame; native adds each parent iframe's content-box offset (from `frames()` rects + border).

- [ ] **Step 1: Tests.** `clickIsTrusted` (a fixture button that writes `isTrusted`), `aCoveredButtonIsNotClicked` (overlay.html → error contains "covered" and "Accept cookies", result stays none), `aHiddenMenuItemStillWorks` (hover.html Settings, answer mentions script), `maskedInputGetsKeysWhenSlowly` (inputs.html B = bbb), `pressEscapeClosesPopover`, `pressControlK`, `enterSubmitsSearch`, `clipboardKeysAreRefused`, `doubleClick` (a fixture `dblclick` counter), `keysNeverLeaveThePage` (AgentInputTests: window with web view + `NSTextField` first responder + a menu item with ⌘W; press `x`, `Escape`, `Meta+w`: field empty, menu action not called).
- [ ] **Step 2:** Fail.
- [ ] **Step 3:** Implement. Events: location = `webView.convert(NSPoint(x: css.x * zoom, y: css.y * zoom), to: nil)` when `webView.window != nil`, else the same point unconverted (zoom = `pageZoom * magnification`); `windowNumber` = the window's or 0; timestamps unique, kept 2 s in a set; `installSwallower()` (called from `AppState.init`) adds a local `.keyDown/.keyUp/.flagsChanged` monitor returning nil for synthetic events. Restore `window.firstResponder` after each action if it changed. Approval kinds: click unchanged; `press_key` → `.pressKey` with `isFormSubmission` = key is Enter and the focused element is in a form (ask the page agent `focusInfo()` → `{inForm, isPassword, description}`); password: card text masked.
- [ ] **Step 4:** Pass; whole `AgentParityTests`.
- [ ] **Step 5:** Commit "Agents click and press keys with real events".

### Task 5: Dialogs and file choosers; `handle_dialog`, `file_upload`

**Files:**
- Create: `Sources/Singularity/Web/PendingModal.swift`
- Modify: `WebTabController.swift` (UI delegate: hold when agent-caused; resume on close/navigation/cancel/quit), `AgentToolbox.swift` (modal line on every tab answer; race actions vs modal; the two tools), `Sources/Singularity/App/AppState.swift` (quit and Space-off resume)
- Test: `AgentParityTests`

**Interfaces:**
- Produces: `enum PendingModal { case alert(message: String), confirm(message: String), prompt(message: String, defaultText: String?), fileChooser(multiple: Bool, directories: Bool) }`; `WebTabController.pendingModal: PendingModal?`; `func answerModal(accept: Bool, text: String?, files: [URL]?)`; `static var modalHoldLimit: Duration = .seconds(120)` (tests set 1 s); `var modalOpenedByCall: UUID?` (the call that opened a file chooser; `file_upload` only answers its own connection's — use the `CallRecord`'s connection id from `MCPHub`, or the tab-busy period if no id exists; document which).
- Produces: `WebTabController.modalAppeared: AsyncStream<Void>` or a polling helper `waitForModalOrCompletion` used by click/press/type.

- [ ] **Step 1: Tests.** `confirmIsReportedAndAccepted` (dialogs.html Delete item → answer starts with "A dialog is waiting" and contains "Delete item?"; `handle_dialog accept` → RESULT confirmed), `alertAndPromptAnswers` (prompt with text "Ann" → `prompt: Ann`), `otherActionsWaitForTheDialog` (click while waiting → refused with the dialog line), `aLateDialogIsReportedOnTheNextCall` (late-dialog.html with `setTimeout(confirm, 300)`), `anUnansweredDialogTimesOut` (limit 1 s → RESULT cancelled), `closingTheTabAnswersTheDialog`, `fileUploadAfterClick` (upload.html: click → "A file chooser is waiting"; `file_upload [invoice.pdf path]` under allowAll → asks: the test answers the inbox approval with Allow via `state.approvals` test hook used in `ApprovalInboxTests`; RESULT `file invoice.pdf 14 bytes`), `fileUploadDeniedLeavesNothing`, `fileUploadWithoutChooserIsRefused`, `aChooserForATabWithNoWindowNeverOpensAPanel` (owner path: not agent-busy → nil at once).
- [ ] **Step 2:** Fail.
- [ ] **Step 3:** Implement per spec "Waiting states". Hold condition: `state.isAgentBusy(tabID) || (tab.openedByAgent && webView.window == nil)`. Every resume path goes through one `finish(_:)` that runs at most once.
- [ ] **Step 4:** Pass; whole suite.
- [ ] **Step 5:** Commit "Dialogs and file choosers wait for the agent".

### Task 6: Snapshot detail, `hover`, `drag`, `wait_for`

**Files:**
- Modify: `PageAgentScript.swift` (options under combobox/listbox, max 20, `selected` mark; table rows `row: "a" | "b"`; slider `value=`; `[draggable]` and `cursor:pointer` elements as `clickable`/`draggable` refs; `hover(ref)`, `drag(from, to)`, `text()` for wait_for), `AgentToolbox.swift` (three tools)
- Test: `AgentParityTests`

**Interfaces:**
- Consumes: `AgentRef`, frames from Task 3 (drag only within one frame: refuse across frames).

- [ ] **Step 1: Tests.** `selectOptionsAreListed` (read shows `option "Tallinn"`), `comboboxOptionsInReadPage` (after typing "Fr": `[n] option "France"` in read_page), `tableRowsKeepTheirCells` (spa orders: `row: "#1042" | "17.50"`), `sliderValueShown`, `hoverShowsAJsMenu` (hover.html Tools → read shows Export), `dragReorders` (drag.html Gamma→Alpha: `order Gamma,Alpha,Beta`), `waitForText` (spa Orders → `wait_for text "Open #1042"` returns found), `waitForTextGone`, `waitForTimesOut` (seconds 1 → "still not"), `lazyListLoadsOnScroll` (click last item repeatedly until Item 50 found ≤ 5 rounds).
- [ ] **Step 2:** Fail.
- [ ] **Step 3:** Implement. Answers for `hover` and `drag` end with "(simulated with script events)".
- [ ] **Step 4:** Pass.
- [ ] **Step 5:** Commit "Read pages in more detail; hover, drag and wait_for".

### Task 7: Pop-ups from agents

**Files:**
- Modify: `AppState.swift:1542` (`openPopup`), `AgentToolbox.swift` (click/press answers name new tabs: compare the Space's tab ids before/after)
- Test: `AgentParityTests`

- [ ] **Step 1: Tests.** `agentPopupIsNotSelected` (newtab.html: both link and `window.open`; selected tab unchanged, new tabs `opened_by_agent`, answer contains `Opened a new tab tab_id`), `ownerPopupIsStillSelected` (`controller.webView` evaluates `window.open` with user gesture via `AgentInput.click` while not agent-busy… use `state.openPopup` directly with no busy mark → selected).
- [ ] **Step 2–4:** Fail, implement (`isAgentBusy(sourceTabID)` → no selection, `openedByAgent = true`), pass.
- [ ] **Step 5:** Commit "A pop-up from an agent's click opens in the background".

### Task 8: Server instructions and the Assistant

**Files:**
- Modify: `Sources/Singularity/MCP/MCPHub.swift` (instructions), `AgentToolbox.swift` (`listSpaces` policy note names the new acting tools), `Plugins/assistant/front.ts`, `Plugins/assistant/provider-claude.ts` (browser prompt), `Plugins/assistant/plugin.json` (0.5.0), `Tests/plugins/assistant/front.test.ts` (find exact path with `ls Tests/plugins`)

- [ ] **Step 1: Tests (Bun).** `doorName("mcp__singularity__my-work_press_key") === "my-work.press_key"` and for each new tool; `toolLine` texts: `Pressed Escape on <title>`, `Waited on <title>`, `Answered a dialog on <title>`, `Chose files on <title>`, `Pointed at something on <title>`, `Dragged on <title>`; `mayWaitForOK` true for press, dialog, files, drag lines and false for wait/point.
- [ ] **Step 2:** `Vendor/bun/bun test Tests/plugins` fails.
- [ ] **Step 3:** Implement; prompt adds: "When a tool says a dialog or a file chooser is waiting, answer it with handle_dialog or file_upload before anything else on that tab. Use wait_for when a page is still loading content. Refs like [f2:5] are inside a frame; use them like any other ref."
- [ ] **Step 4:** Bun tests and `swift test --filter "PluginDoorTests|AgentParityTests"` pass.
- [ ] **Step 5:** Commit "The Assistant knows the new browser tools (0.5.0)".

### Task 9: Docs, full run, bench on a bundle, release

- [ ] **Step 1:** `CLAUDE.md`: Page agent (all frames, handshake, native input + swallower, modal states), Approvals (new kinds, file upload always asks), Assistant line (0.5.0); architecture list gets `AgentInput`, `AgentFrames`, `PendingModal`, `AgentKeys`, `UploadFiles`. `IDEAS.md`: `evaluate` under "New, not yet decided". Spec: "As built" section.
- [ ] **Step 2:** `scripts/test.sh` passes.
- [ ] **Step 3:** Bundle at `/private/tmp/sg-pp/Singularity.app`, `open -g -n -a … --env SINGULARITY_HOME=/private/tmp/sg-ph`, bench by hand through the socket on a background tab (never activate it); record results in the spec's "As built".
- [ ] **Step 4:** Whole-branch review (fresh reviewer), fix findings.
- [ ] **Step 5:** `git fetch`; merge into `main` in the worktree that has it (check `git worktree list`, clean and idle), push, `scripts/release.sh <next minor> --yes` there; tell the owner where it ran.
