# Assistant, part 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A plugin can show its own TSX page in a right-hand panel or a tab and keep one approved program running; the bundled Assistant plugin uses both for a plain streaming chat on the user's own Claude Code sign-in.

**Architecture:** Every rule is a pure type in `SingularityCore` with tests (manifest keys, approval text, launch rule, program environment, wire messages, import map, where the page is shown). `PluginProcess` gains a program bridge: the sandboxed Bun asks, the app starts the pinned program outside the sandbox and carries stdin/stdout as wire messages. The page is served from the plugin folder by a `WKURLSchemeHandler` under `singularity-plugin://<id>/`, compiled like TS/TSX artifacts, in one locked `WKWebView` per plugin that sits either in the panel or in a `TabKind.plugin` tab. The Assistant is plain plugin files: the Agent SDK in `background.ts` with `spawnClaudeCodeProcess` wired to `singularity.spawn`.

**Tech Stack:** Swift, SwiftUI, AppKit, WebKit; Swift Testing; TypeScript on the bundled Bun; `@anthropic-ai/claude-agent-sdk` 0.3.323 and Preact as pinned *plugin* packages.

**Spec:** `docs/superpowers/specs/2026-11-13-assistant-part1-design.md`

## Global Constraints

- No new app dependency (`Package.swift` unchanged). The SDK and Preact are packages of the plugin only.
- Singularity never shows a Claude login and never reads, stores or forwards a token or API key.
- No test, script or trial runs the real `claude` (or `codex`) or touches `~/.claude*`; tests use fixture programs. The one exception is the opt-in test of Task 8.
- No test makes a window key; test copies are never activated and get no input.
- A copy started with `SINGULARITY_HOME` refuses every program start unless `SINGULARITY_REAL_PROGRAMS=1`.
- The Assistant starts its program with no tools (`tools: []`) and none of the user's settings (`settingSources: []`).
- In the interface the plugin is "Assistant"; no new string calls it an agent, and "Claude Code" appears in no string except a pinned path.
- Everything a model or program sends is untrusted text: rendered as text nodes, never as HTML.
- Sandbox profile unchanged. If a task seems to need a wider sandbox, stop and report.
- Boring, readable Swift with comments on the non-obvious AppKit/WebKit parts; follow the patterns of the neighbouring files.
- Build and test with `source scripts/env.sh` first (plain `swift build` fails); never run `xcode-select -s`, `scripts/run.sh`, `open https://…`, or anything that quits or activates the owner's running copy.

## Review Focus

1. A panel plugin approved with no Space switched on: its background still runs and its page's messages are answered. Test in Task 1 (rule) and Task 5 (wiring).
2. The program writes faster than the plugin reads (megabytes of output): memory stays bounded and nothing is lost or reordered. Test in Task 2.
3. The plugin stops, is paused or the app quits while its program runs: the program is gone within 3 s. Test in Task 2.
4. The page tries to reach the internet (fetch, image, navigation, new window): every route fails. Test in Task 4.
5. `space.json` with a `plugin` tab whose plugin is missing or paused, and an old `space.json` without the kind: both load; the tab shows the native "isn't running" page. Tests in Task 3 and Task 5.
6. An answer containing `<script>`, `<img onerror>` and Markdown links: shown as text, nothing runs or loads. Test in Task 7.

---

### Task 1: Core: manifest keys, approval text, launch rule, packages without optional ones

**Files:** modify `Sources/SingularityCore/Plugins/PluginManifest.swift`, `PermissionDescriptions.swift`, `PluginErrorMessages.swift` (and where `PluginError` is declared), `PluginScan.swift`, `PluginPackages.swift`; tests in `Tests/SingularityCoreTests/` (new `PluginPanelManifestTests.swift`, plus the existing plugin test files where they assert whole lists).

**Produces:**
- `PluginManifest.Panel { page: String, title: String }`, `PluginManifest.panel: Panel?`
- `PluginManifest.Permissions.programs: [String]`, `.programEnv: [String]` (both default `[]`; the hand-written decoder's `known` set gets both names)
- New `PluginError` cases with these messages (after "This folder isn't a plugin Singularity can use: " / "Problem: "):
  - `.refusedProgram(name)`: `it asks to keep “<name>” running, which plugins may not`
  - `.programsNeedBackground`: `it asks to keep a program running but has no background program`
  - `.invalidProgramEnv(name)`: `it asks to set “<name>” for its program, which plugins may not`
  - `.invalidPanelTitle`: `its panel needs a title of 1 to 40 characters`
  - a missing `panel.page` uses the existing `.missingFile`
- `PluginReview`/`PluginApproval`: program names are resolved and pinned in the existing `commandPaths` map (same resolver, same "path changed, ask again" behaviour); a program that can't be found blocks approval exactly as a command does.
- `PluginLaunch.decide`: a manifest with `panel` is never `.switchedOff` for having no enabled Space.
- `PluginManifest.hasPageScript` unchanged; new `PluginManifest.showsSpaceSwitches: Bool` = `page != nil`.

**Rules to implement (tests first, one test per rule):**
- `programs`: each name passes `CommandPolicy.isValidName` and is not `isRefused`; no duplicates; at most 4; non-empty requires `background`.
- `programEnv`: each matches `^[A-Z][A-Z0-9_]{0,63}$`; refused exactly: `HOME USER LOGNAME PATH TMPDIR LANG SHELL PWD`, anything starting `DYLD_` or `LD_`, and `SINGULARITY_` anything; non-empty requires non-empty `programs`.
- `panel.title`: trimmed, 1...40 characters, no line breaks. `panel.page`: same file rule as `background`.
- Check order in `validate`: after `commands`, before files.
- `PermissionDescriptions.lines` gains `hasPanel: Bool = false` and emits, in this order after the commands lines:
  - `Shows its own panel and tab` (when `hasPanel`)
  - per program, sorted: `Keeps <path or name> running and talks to it. This program is not sandboxed: it uses the internet and acts as you`
  - `Passes these settings to it: A, B` (when `programEnv` is non-empty, sorted)
  - the network line treats `programs` like `commands` ("…; the programs it runs can").
- `PluginPackages`' install command adds `--omit=optional`; its argument-list test is updated. Find out whether the lock check counts optional packages and keep `Summary.lockedCount` meaning "what will be installed".

- [ ] Write the failing tests (decoding with and without the new keys; an unknown permission key still fails; every rule above with one bad and one good value; the description lines as exact strings; `decide` with `panel` and no Spaces; the install arguments).
- [ ] Run `source scripts/env.sh && swift test --filter PluginPanelManifestTests` and see them fail.
- [ ] Implement.
- [ ] Run `swift test --filter SingularityCoreTests` and see everything pass.
- [ ] Commit: "Plugins: panel, programs and programEnv in the manifest; packages without optional ones".

### Task 2: Core: the program bridge (wire, environment, PluginProcess, host.ts)

**Files:** create `Sources/SingularityCore/Plugins/PluginProgram.swift`; modify `PluginWire.swift`, `PluginProcess.swift`, `Resources/plugin-host/host.ts`; tests `Tests/SingularityCoreTests/PluginProgramTests.swift` (follow how the existing `PluginProcess` tests find Bun and skip without it), fixture program `Tests/SingularityCoreTests/Fixtures/echo-program.sh` or a tiny compiled-on-the-fly script run by `/bin/cat`-style system tools.

**Consumes:** Task 1's `permissions.programs`, `.programEnv`, pinned paths in `commandPaths`.

**Produces — wire (`PluginWire`, JSON `kind` = case name):**
- plugin → app: `startProgram(programID: Int, program: String, arguments: [String], environment: [String: String])`, `programInput(programID: Int, data: String)` (base64), `closeProgramInput(programID: Int)`, `killProgram(programID: Int, signal: String)` (`"SIGTERM"`, `"SIGKILL"`, `"SIGINT"`; anything else is treated as SIGTERM), `programOutputRead(programID: Int, bytes: Int)`, `panelPost(payload: JSONValue)`
- app → plugin: `programStarted(programID: Int)`, `programFailed(programID: Int, reason: String)`, `programOutput(programID: Int, data: String)` (base64, at most 48 KB of bytes a message), `programExit(programID: Int, status: Int32?, signal: String?)`, `panelMessage(requestID: Int, payload: JSONValue)` (answered with the existing `.reply`)

**Produces — Swift:**
- `ProgramPolicy.spawnAllowed(environment: [String: String]) -> Bool`: false when `SINGULARITY_HOME` is set and `SINGULARITY_REAL_PROGRAMS` is not exactly `"1"`.
- `ProgramEnvironment.make(home: String, user: String, loginPath: String, tmpdir: String, appVersion: String, requested: [String: String], allowed: [String]) -> [String: String]`: exactly `HOME`, `USER`, `LOGNAME`, `PATH`, `TMPDIR`, `LANG=en_US.UTF-8`, `CLAUDE_AGENT_SDK_CLIENT_APP=singularity/<appVersion>`, plus each `requested` pair whose name is in `allowed` and whose value is non-empty and has no NUL. Nothing else.
- `PluginProcess.init` gains `programsAllowed: Bool` and `programEnvironment: @Sendable (_ requested: [String: String]) -> [String: String]` (the manager fills them in Task 5; tests pass closures), and a callback `onPanelPost: (@Sendable (JSONValue) -> Void)?`.
- `PluginSupervisor` forwards `send(.panelMessage…)` and the callback like its other messages.

**Rules:**
- A start is refused with `programFailed` when: `programsAllowed` is false (`programs are off in a test copy`), the name is not in `manifest.permissions.programs` or has no pinned path (`not allowed by the manifest`), the pinned path fails `PluginLaunch.isAllowedProgram` (`the program is missing or changed`), or one is already running (`a program is already running`). One running program per plugin.
- The program is started by path, never through a shell; working directory = the plugin's data folder; stdin, stdout piped; stderr read line by line into the plugin log (level `info`, prefix `<program>: `, each line cut to 2000 characters).
- Backpressure: the app stops reading the program's stdout while more than 1 MB has been sent and not yet reported by `programOutputRead`; it resumes below that. Input from the plugin is written in order on a serial queue; a write to a dead program is dropped.
- Ending: `stop()`/`terminateNow()` of the `PluginProcess`, the plugin's own exit, and `killProgram` all end the program. SIGTERM first; SIGKILL after 2 s if it is still there. Start it as its own process group (as `CommandBroker.run` does for its children, or with `posix_spawn` and `POSIX_SPAWN_SETPGROUP`) and signal the group, so what it started goes too.
- `programExit` is sent once, after all output has been delivered.

**Produces — `host.ts` (the `singularity` object of the background):**
- `singularity.spawn(program: string, args: string[], options?: { env?: Record<string, string> }): SpawnedProgram` where `SpawnedProgram` has `stdin: Writable`, `stdout: Readable` (Node streams), `killed: boolean`, `exitCode: number | null`, `kill(signal?: string): boolean`, `on/once/off("exit" | "error", listener)`. `error` fires with the `programFailed` reason; then `exit` with code 126.
- `stdout` reports `programOutputRead` as its consumer takes data (in `_read`), so a slow reader slows the program.
- `singularity.panel.post(payload: unknown): void` (JSON, at most 256 KB, larger throws).
- `panelMessage` is answered through the existing `onPageMessage` handler with `{ tabID: "panel", frameHost: "", payload }`.
- The `declare module "singularity"` types that plugins see (wherever the template's types live) get the new members.

- [ ] Write the failing Swift tests: wire round-trips for every new case; `spawnAllowed` (4 combinations); `ProgramEnvironment.make` (exact key set; a requested name not allowed is dropped; empty value dropped).
- [ ] Write the failing end-to-end tests with real Bun and a fixture program through `PluginProcess` (skipped when `Vendor/bun/bun` is missing, as the existing ones are): echo (what goes into stdin comes out of stdout, binary-safe); 5 MB of output read slowly arrives complete and in order while the app never holds more than ~1 MB unread (Review Focus 2); exit status is delivered after the last byte; `kill`; a program that ignores SIGTERM is gone within 3 s of `stop()` and so is a child it started (Review Focus 3); the four refusals; a second `spawn` while one runs; `panelPost` reaches the callback; `panelMessage` is answered by `onPageMessage`.
- [ ] See them fail, implement, see `swift test --filter SingularityCoreTests` pass.
- [ ] Commit: "Plugins: a running program, bridged between the sandbox and the app".

### Task 3: Core: the plugin tab kind, where a plugin's page is, the import map

**Files:** modify `Sources/SingularityCore/Model/BrowserTab.swift`, `Settings/AppSettings.swift`, every `switch` over `TabKind` in Core; create `Sources/SingularityCore/Plugins/PluginSurface.swift`, `Sources/SingularityCore/Plugins/PluginImportMap.swift`; tests `Tests/SingularityCoreTests/PluginSurfaceTests.swift`.

**Produces:**
- `TabKind.plugin(pluginID: String)`; encoded in the style of the existing cases; old files without it load unchanged; a file written with it loads back. Its default title is the manifest's panel title when known, else the id. No project, no URL, not a web tab for any "is web" helper.
- `AppSettings.pluginPanel: String?` (the plugin whose page the panel shows; nil = closed) and `.pluginPanelWidth: Double`; `PluginPanelLayout.defaultWidth = 380`, `.minWidth = 300`, `.maxWidth = 720`, `.clamp(_:)`. Tolerant decoding as for the other settings.
- `enum PluginPagePlace: Equatable { case hidden, panel, tab(space: UUID, tab: UUID) }`
- `PluginSurface.place(of pluginID: String, panel: String?, spaces: [Space]) -> PluginPagePlace`: a tab wins over the panel; the first tab found in Space order.
- `PluginSurface.tabsToRemove(for pluginID: String, in space: Space) -> [UUID]` (every plugin tab of that id; used so there is never more than one).
- `PluginImportMap.make(dependencies: [String], packageJSON: (String) -> Data?) -> [String: String]`: for each declared package name, read `node_modules/<name>/package.json` through the closure and map `<name>` and each `exports` subpath (`./hooks` → `<name>/hooks`) to `/node_modules/<name>/<file>`. For a conditions object take the first of `browser`, `import`, `module`, `default` that is a string ending in `.js` or `.mjs` (look one level into nested condition objects); without `exports`, use `module`, else `main`. Skip `./package.json`, patterns with `*`, and anything whose target has `..` or does not start with `./`. Packages that can't be read are left out.

- [ ] Failing tests: coding of the new kind both ways and an old fixture file (Review Focus 5); settings decoding (absent, wrong type, out-of-range width is clamped); `place` (hidden, panel, tab, tab and panel both set → tab); `tabsToRemove`; import map for a Preact-shaped `package.json` (`.`, `./hooks`, `./jsx-runtime` with `browser`/`import` conditions), a package with only `main`, a hostile target (`../../x.js`), a `*` pattern.
- [ ] See them fail, implement (the compiler lists every `switch` that needs the new case; in Core give each the behaviour of "not a web page, not a terminal, not an artifact"), see Core tests pass.
- [ ] Commit: "Plugin tab kind, the page's place, the import map".

### Task 4: App: serving and locking a plugin's page

**Files:** create `Sources/Singularity/Plugins/PluginPageServer.swift` (the scheme handler), `PluginPageHost.swift` (one web view per plugin + its bridge); modify nothing else yet; tests `Tests/SingularityAppTests/PluginPageTests.swift` (nested in `AppTests`, `MainRunLoopGuard` first, as the other suites).

**Consumes:** Task 3's `PluginImportMap.make`; the existing `ArtifactScripts` / `ArtifactCompiler` / `PluginPageCompiler.runHostScript` for compiling TS/TSX; the existing artifact shell page for a script opened as a page.

**Produces:**
- `PluginPageServer: NSObject, WKURLSchemeHandler` with `static let scheme = "singularity-plugin"`, `init(pluginID: String, folder: URL, entry: String, compile: …)`; URLs are `singularity-plugin://<id>/<path>`; `/` serves the entry (`panel.page`).
- `@MainActor final class PluginPageHost` with `init(pluginID: String, folder: URL, manifest: PluginManifest, send: @escaping (JSONValue) async -> JSONValue?)`, `let webView: WKWebView`, `func post(_ payload: JSONValue)`, `func reload()`, `func tearDown()`.

**Rules:**
- Served: regular files inside the folder after symlinks are resolved; never a path with `..`, a dot-file or dot-folder component (so no `.git`), `plugin.json`, `background` or other `.ts` server-side files are fine to serve (they are the plugin's own reviewed source). GET only; anything else 405; missing 404. MIME types from `ArtifactFiles`.
- `.ts/.tsx/.jsx/.mts` are compiled on request like artifacts (JSX runtime import must resolve to the plugin's declared package: a file may say `/** @jsxImportSource preact */`; check what `transpile-artifact.ts` emits and make `preact/jsx-runtime` work through the import map). Extension-less relative imports resolve as `ArtifactScripts.resolveModule` does. A compile error comes back as the module that shows the error, as for artifacts.
- When the entry is a script, the shell page contains the import map (from `package.json` dependencies and `PluginImportMap.make`) and the module script, both with a per-response nonce.
- Every response carries `Content-Security-Policy: default-src 'none'; script-src 'self' 'nonce-<n>'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self'; connect-src 'none'; base-uri 'none'; form-action 'none'; frame-src 'none'`, `X-Content-Type-Options: nosniff`, `Cache-Control: no-store`. If WebKit does not match `'self'` for a custom scheme, name the origin explicitly; the test below decides.
- The web view: `WKWebsiteDataStore.nonPersistent()`; its own `WKProcessPool`-independent configuration; no page agent, capture or plugin user scripts; `developerExtrasEnabled` as web tabs have; navigation delegate allows only `singularity-plugin://<id>/…` in the main frame and cancels everything else; `createWebViewWith` returns nil; downloads cancelled; media capture denied; JavaScript dialogs not shown.
- The page API, injected at document start in the page's own world: `window.singularity = { send(payload): Promise<unknown>, onMessage(handler): void }`. `send` goes through a `WKScriptMessageHandlerWithReply` named `singularityPanel`; the native side accepts a message only from the main frame whose `securityOrigin` is this plugin's scheme and host, refuses payloads over 256 KB (`the message is larger than 256 KB`), and rejects with `the plugin isn't running or didn't answer` when `send` returns nil. `post` delivers to the `onMessage` handler (queued until a handler is set; dropped when the page is not loaded).

- [ ] Failing app tests with a temp plugin folder and an off-screen web view: the entry `.tsx` renders (a fixture page that writes a marker into `document.title` using an import of a sibling `.ts` file and of a fixture package through the import map); a file outside the folder, a dot-file and a symlink pointing out are 404; the policy header is present; from the page `fetch("http://127.0.0.1:<fixture port>/")`, an `<img>` to it, `location.href = …`, `window.open(…)` all fail while the fixture server sees no request (Review Focus 4; reuse the fixture site helper of `PageCaptureTests`); `send` round-trips through a fake `send` closure; a 300 KB payload is refused; `post` reaches `onMessage`, also when called before the handler is set.
- [ ] See them fail, implement, see `swift test --filter PluginPageTests` pass.
- [ ] Commit: "Plugins: a plugin's own page, served and locked".

### Task 5: App: PluginManager wiring (programs, panel messages, page hosts, not-running reason)

**Files:** modify `Sources/Singularity/Plugins/PluginManager.swift`, `PluginApprovalSheet.swift`, Settings → Plugins view; tests in `Tests/SingularityAppTests/PluginPanelTests.swift`.

**Consumes:** Tasks 1, 2, 4.

**Produces (on `PluginManager`):**
- `func pageHost(for id: String) -> PluginPageHost?`: the host while the plugin's background runs, created on first use, torn down when the supervisor stops, reloaded when it restarts.
- `func panelPlugins() -> [InstalledPlugin]` (valid manifest with `panel`, sorted by title) and `func panelTitle(_ id: String) -> String?`.
- `func notRunningReason(_ id: String) -> String`: `PluginStatusText.describe`'s text for the plugin, or `This plugin isn't installed.` when unknown.
- Panel sends go `PluginPageHost.send` → supervisor `.panelMessage` → `.reply`, with the same pending-request bookkeeping and timeout as page messages, and **no** Space check (Review Focus 1). `.panelPost` → `pageHost.post`.
- When it launches a plugin it passes `programsAllowed: ProgramPolicy.spawnAllowed(environment: ProcessInfo.processInfo.environment)` and a `programEnvironment` closure built from the real home folder, user name, the login shell's PATH (resolve it once per app run off the main actor, reusing `CommandBroker`'s login-PATH code) and the bundle's short version.
- The approval sheet and Settings → Plugins pass `hasPanel` to `PermissionDescriptions.lines`, show the per-Space switches only when `manifest.showsSpaceSwitches`, and for a panel plugin with no page script the sheet's Space list is replaced by one line: `Its panel is available in every Space.`

- [ ] Failing app tests with a temp plugins folder and a small fixture plugin (a `background.ts` that answers panel messages and posts back; follow how existing manager-level tests, if any, approve without UI; else drive `PluginSupervisor` + `PluginPageHost` directly): a panel plugin with no Space switched on launches and answers a panel message; `pageHost` is nil while paused and `notRunningReason` is the status text; stopping the plugin tears the host down.
- [ ] See them fail, implement, see them pass together with `swift test --filter SingularityAppTests` (run in the background with a generous timeout).
- [ ] Commit: "Plugins: the manager runs panel plugins, their programs and their page".

### Task 6: App: the frame (right-hand panel, plugin tab, commands)

**Files:** create `Sources/Singularity/Plugins/PluginPanelView.swift` (panel column, header, width strip, the native "isn't running" view, the hosted web view), modify `App/MainView.swift`, `App/AppState.swift`, menu commands, the palette's command list, the sidebar's tab row and the content area's switch over `TabKind` (and `PaneContainerView`/`HostedView` so a plugin tab hosts the page), `MCP/AgentToolbox.swift`; tests `Tests/SingularityAppTests/PluginSurfaceStateTests.swift`.

**Consumes:** Task 3's `PluginSurface`, `PluginPanelLayout`, settings keys; Task 5's `pageHost(for:)`, `panelPlugins()`, `notRunningReason`.

**Produces (on `AppState`):**
- `func togglePluginPanel()`: closed → opens the panel for the last shown plugin, else the first of `panelPlugins()`; if that plugin's page is a tab, selects the tab instead (through the user-facing selection path, so the welcome flow closes); open → closes.
- `func showPluginPanel(_ id: String)`, `func closePluginPanel()`
- `func openPluginPageAsTab(_ id: String)`: adds a `.plugin` tab to the selected Space after removing `PluginSurface.tabsToRemove` everywhere, closes the panel, selects the tab.
- `func movePluginPageToPanel(_ id: String)`: removes the plugin's tabs, opens the panel.
- All settings writes through `updateSettings`.

**Rules:**
- The panel is a column at the right of the main window's content area (to the right of splits), with a 1-pt separator and a draggable strip on its left edge that works like the sidebar's width strip (live while dragging, written on mouse-up, double-click resets, clamped by `PluginPanelLayout`). Not in little windows. Hidden while `welcomeCoversWindow`.
- Header row: the plugin's title on the left; a menu button on the right with `Open as Tab` and `Close`; when `panelPlugins()` has more than one, the menu also lists them to switch. No `.help()` if the header sits in the title-bar strip; give the panel its own top inset so it does not.
- Body: `pageHost(for:)?.webView` hosted the way `HostedView` hosts a tab's view (only the newest container owns it), else the native view: title `<Title> isn't running`, the reason text shown with `Text(verbatim:)`, a button `Open Plugin Settings` (opens Settings on the Plugins tab the way existing code opens Settings).
- A `.plugin` tab: sidebar row with a puzzle-piece SF Symbol and the panel title; content = the same body view; can be pinned, moved, split, closed like any tab; closing it only hides the page. Its context menu has `Move to Side Panel`. Find, Reload, Zoom, Print, Back/Forward, Open Location's "current address" and the address row are off or absent for it, following how terminal tabs are treated.
- View menu: `Show <Title>` / `Hide <Title>` with ⌃⌘J (check it is free in the app's commands; if taken use ⌥⌘J and say so in the commit), disabled when there is no panel plugin or the welcome flow covers the window. Palette: `Show <Title>`, `Open <Title> as Tab`, `Move <Title> to Side Panel` as they apply.
- Agent tools: `list_tabs` leaves plugin tabs out and every tool that takes a tab refuses one (`not a web page`), as the code already does for terminals where applicable.
- Deleting a Space or removing the plugin needs no special case beyond the existing tab removal; a `.plugin` tab of a missing plugin shows the native view.

- [ ] Failing app tests with `TestAppState` and a fixture panel plugin (or a manager stub if `PluginManager` can be given one): toggle opens and closes and writes the setting; Open as Tab makes exactly one tab, closes the panel, and a second Open as Tab does not make a second; Move to Side Panel removes it; toggle while the page is a tab selects that tab; a `.plugin` tab of an unknown plugin loads from disk and its body is the native view with `This plugin isn't installed.` (Review Focus 5); `list_tabs` omits it; the toggle does nothing while the welcome flow covers the window.
- [ ] See them fail, implement, build, see the app tests pass.
- [ ] Commit: "A plugin's page in a right-hand panel or a tab".

### Task 7: The Assistant plugin

**Files:** create `Plugins/assistant/plugin.json`, `package.json`, `bun.lock`, `README.md`, `background.ts`, `provider.ts` (the interface), `provider-claude.ts`, `conversation.ts` (the saved copy), `panel.tsx`, `markdown.ts`, `panel.css`; tests `Tests/plugins/assistant/*.test.ts` (follow `Tests/plugins/1password` for how `singularity` is faked and how `scripts/test.sh` runs them).

**Consumes:** Task 2's `singularity.spawn`, `singularity.panel.post`, `onPageMessage` with `tabID: "panel"`; Task 4's page API.

**`plugin.json`:** id `assistant`, name `Assistant`, description `A built-in helper you can chat with, running on your own Claude sign-in.`, `background: "background.ts"`, `panel: { "page": "panel.tsx", "title": "Assistant" }`, `permissions: { "programs": ["claude"], "programEnv": ["CLAUDE_CONFIG_DIR", "CLAUDE_AGENT_SDK_VERSION", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_SDK_READS_SESSION_STATE"] }`. Packages: `@anthropic-ai/claude-agent-sdk` exactly `0.3.323`, `preact` at its current exact version; make `bun.lock` with `Vendor/bun/bun install --omit=optional --ignore-scripts` in a scratch copy and check it passes `PluginPackages.check`. `node_modules` is not committed.

**`provider.ts` (the seam for other providers; only Claude implements it):**
```ts
export type ProviderEvent =
  | { type: "ready"; model: string; billing: "plan" | "api"; models: { id: string; name: string }[]; providerVersion: string }
  | { type: "text"; delta: string }
  | { type: "done" }
  | { type: "error"; kind: "signedOut" | "limit" | "programEnded" | "programsOff" | "other"; message: string }
  | { type: "session"; id: string };
export interface Provider {
  start(options: { resume?: string; model?: string; configFolder?: string }, emit: (e: ProviderEvent) => void): void;
  send(text: string): void;
  interrupt(): void;
  setModel(id: string): void;
  stop(): void;
}
```

**`provider-claude.ts`:** one SDK `query` in streaming-input mode with `pathToClaudeCodeExecutable: "claude"`, `tools: []`, `settingSources: []`, `mcpServers: {}`, `includePartialMessages: true`, `resume` when given, `model` when given, a short `systemPrompt` (it is the Assistant inside the Singularity browser; in this version it cannot see pages, tabs or terminals and cannot act, and says so when asked), and `spawnClaudeCodeProcess: (o) => singularity.spawn("claude", o.args, { env: … })` passing only the four `programEnv` names (the SDK's three from `o.env`, `CLAUDE_CONFIG_DIR` from the setting when non-empty). `billing` is `"plan"` when the init message's `apiKeySource` is `"none"`, else `"api"`. Models from the SDK's supported-models call. Map failures: the spawn `error` `programs are off in a test copy` → `programsOff`; an authentication failure → `signedOut`; a usage or rate limit → `limit`; the program exiting mid-conversation → `programEnded`; a failed `resume` → emit `error` `other` once, then start again without `resume`. Read the SDK's `sdk.d.ts` in a scratch install for the exact message and method names; do not guess them.

**`background.ts`:** owns one `Provider` and the state; page ↔ background messages (all JSON):
- page → background (`singularity.send`): `{ type: "hello" }` → replies with the full state `{ messages, status, model, models, billing, billingNoticeSeen, configFolder, providerVersion, sdkVersion }`; `{ type: "send", text }`; `{ type: "stop" }`; `{ type: "newChat" }`; `{ type: "setModel", id }`; `{ type: "setConfigFolder", path }` (restarts the provider); `{ type: "retry" }`; `{ type: "billingSeen" }`.
- background → page (`singularity.panel.post`): `{ type: "delta", text }`, `{ type: "state", …same shape as hello's reply }` on every other change.
- `status` is one of `starting`, `ready`, `answering`, `signedOut`, `limit`, `programEnded`, `programsOff`, `error`.
- The provider starts on the first `hello`, not at plugin start (no usage until the panel is opened).
- `singularity.storage` keys: `session` (id), `model`, `configFolder`, `billing` (last seen), `billingNoticeSeen`. When `billing` differs from the stored one, or is `api` for the first time, `billingNoticeSeen` becomes false and `send` is held until `billingSeen`.

**`conversation.ts`:** the visible messages `{ role: "user" | "assistant", text: string, stale?: boolean }[]` in `<data folder>/conversation.json` (data folder = `process.env.HOME`), written atomically (temp file + rename) at most once a second while streaming and at `done`; deleted by `newChat`; capped at the last 400 messages; an unreadable file counts as empty. After a failed resume the loaded messages are marked `stale`.

**`panel.tsx` (Preact, `/** @jsxImportSource preact */`), `panel.css`:** message list (the Assistant's text through `markdown.ts`, stale messages greyed with one line `Earlier conversation. The Assistant no longer remembers it.`), an input (Return sends, Shift-Return new line, disabled while not `ready`), Stop while `answering`, a header row with `New Chat`, the model menu and the billing label (`Claude plan` / `API billing`), a small settings view (gear button) with the one field `Claude config folder` (placeholder `Default`) and both versions. State texts, exactly:
- `signedOut`: `Claude isn't signed in on this Mac. Open a terminal tab, run claude and sign in, then press Try Again.`
- `limit`: `Your Claude usage limit is reached. Try again later.`
- `programEnded`: `The connection to Claude ended.` + `Try Again`
- `programsOff`: `Programs are off in this test copy of Singularity.`
- billing notice (`api`): `This chat is billed to an API account, not a Claude plan.` + `OK`; (`plan` after `api`): `This chat now uses your Claude plan.` + `OK`
- empty chat: `Ask anything. In this version the Assistant can't see your pages or act for you yet.`
Colours follow `prefers-color-scheme`; system font; no external resources.

**`markdown.ts`:** `render(text: string): Node[]` building DOM nodes only (never `innerHTML`): paragraphs, fenced code blocks, inline code, bold, italic, `#` headings, `-`/`1.` lists. A link is shown as its text followed by the address in parentheses, not as an anchor. HTML in the text stays text.

**`README.md`:** what it does, that it runs your own installed Claude program and counts against your Claude plan (or API account), what part 1 cannot do, the permissions in plain words.

- [ ] Failing Bun tests: `markdown` (each construct; `<script>alert(1)</script>`, `<img src=x onerror=…>` and `[x](javascript:…)` produce only text nodes — Review Focus 6); `conversation` (round-trip, cap, unreadable file, delete, stale marking); `background` with a fake provider and fake `singularity` (hello before start, deltas forwarded, state after done, held send until `billingSeen`, `newChat` clears file and session, model and config folder stored, failed resume → stale + new session); `provider-claude` with a fake `singularity.spawn` that replays a recorded stream-json exchange (ready with `plan`, text deltas, done) and one where the program fails with `programs are off in a test copy`.
- [ ] See them fail (`Vendor/bun/bun test Tests/plugins/assistant`), implement, see them pass.
- [ ] `Vendor/bun/bun build --no-bundle Plugins/assistant/panel.tsx` compiles; a Core test loads `Plugins/assistant` with `PluginManifest.load` and gets the expected approval lines (add to the test file that already loads the bundled plugins, or to Task 1's).
- [ ] Commit: "The Assistant plugin: a plain chat on your own Claude sign-in".

### Task 8: End to end, documents, release

**Files:** create `Tests/SingularityAppTests/RealAssistantTests.swift`; modify `scripts/test.sh` only if the new Bun test folder is not already picked up; `CLAUDE.md`, `docs/plugins/AUTHORING.md`, `IDEAS.md`, `docs/superpowers/specs/2026-11-09-plugins-design.md` (round 2 note), the spec's new "As built" section.

- [ ] App test (runs when Bun is present; no network, so the plugin's real packages are never installed in tests): copy `Plugins/assistant` to a temp folder and add a small fixture `node_modules/preact` that provides what `panel.tsx` imports; the manifest loads, `panel.tsx`, `markdown.ts` and `panel.css` are served and compile through `PluginPageServer`, and the page sends its first `hello` to a fake `send` closure and renders the empty-chat text from the reply.
- [ ] `RealAssistantTests` (opt-in: runs only when `SINGULARITY_REAL_ASSISTANT=1`; skipped by `scripts/test.sh`): installs the plugin's packages into a temp copy with the bundled Bun, runs `background.ts` under the real `PluginProcess` with the real pinned `claude` and `programsAllowed: true`, sends `hello` then one `send` ("Reply with the single word: pong"), and expects `ready` with a billing value, at least one delta and `ready` again within 60 s. Off-screen, no window.
- [ ] Run `scripts/test.sh` in full; fix what fails.
- [ ] Build a full bundle beside the owner's copy (`APP=/private/tmp/sg-app/Singularity.app scripts/build-app.sh`), check `Contents/Resources/Plugins/assistant` is there without `node_modules`; remove the bundle afterwards.
- [ ] Documents: `CLAUDE.md` (scope-change line for the Assistant parts 1 to 3 with the owner's decisions; `TabKind.plugin`; the architecture list's new files; a "Plugin panels and programs" key-decision entry with the things that bit us; the third exception for Claude's session files; `SINGULARITY_REAL_PROGRAMS`); `AUTHORING.md` (`panel`, the page API, `programs`, `programEnv`, `spawn`, `panel.post`, new error messages, the review checklist items from the spec's "Known weaknesses"); `IDEAS.md` (the Claude Chat item → built as Assistant part 1, parts 2 and 3 next, other providers); the plugins design's round 2 note; the spec's "As built" (every place the build differs from the design).
- [ ] Commit, merge `assistant` into `main` (fast-forward), `scripts/release.sh 0.7.0 --yes`.
