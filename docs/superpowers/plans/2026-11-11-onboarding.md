# First-run Onboarding and Live Orb Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A four-step welcome flow on a brand-new install (Space, agents, plugins), reopenable from the menu, plus a live Metal orb that also replaces the static orb in an empty Space.

**Architecture:** Pure decisions (first-run test, step sequence, agent commands and config parsing, bundled-plugin listing) live in `SingularityCore` with unit tests. The app adds one `OnboardingView` that `MainView` shows instead of the sidebar and content while `AppState.onboarding` is set, an `AgentConnector` shared by the flow and Settings → Agents, and an `OrbView` (an `MTKView` whose shader is compiled from source at run time, so no build step and it works in the bare debug binary).

**Tech Stack:** Swift 6, SwiftUI + AppKit, MetalKit (system framework, not a new dependency), Swift Testing.

**Spec:** `docs/superpowers/specs/2026-11-11-onboarding-design.md`. Read it first; this plan argues from it.

## Global Constraints

- Swift + SwiftUI, AppKit where needed; macOS 14+; **no new package dependencies**.
- Boring, readable Swift; comment the non-obvious AppKit/Metal parts (the owner reads TypeScript/PHP more easily than Swift).
- Build and test only through the scripts: `source scripts/env.sh` then `swift build` / `scripts/test.sh`. **Never** run `scripts/build-app.sh` or `scripts/run.sh` without `APP=/private/tmp/sg-app/Singularity.app` (the owner's copy runs from `build/`), never quit the owner's copy, never run `xcode-select -s`.
- Try the app only with `SINGULARITY_HOME=/private/tmp/sg-test` (delete that folder first for a brand-new install).
- **Never change the real `~/.claude.json` or `~/.codex/config.toml`, and never run `claude mcp add/remove` or `codex mcp add/remove` for real** while building or testing. Tests use fakes.
- No Space is opened to agents unless the user flips its switch; policy stays `.ask`. A plugin is never approved outside `PluginApprovalSheet`.
- No SwiftUI `.help()` on controls in the window's title-bar strip (it eats clicks there).
- New app-test suites go in `extension AppTests { … }` and touch `MainRunLoopGuard.start` first.
- Commit after each task, on branch `onboarding`, message ending with the line
  `Claude-Session: https://claude.ai/code/session_01X5WAkwWHovC81NVLjXVSWV`.

## Review Focus

1. **A Space name that is empty, only spaces, or has no letters/digits (e.g. "🎉")** in step 2: Continue is disabled for empty/whitespace; a name with no sluggable characters still gets a valid, unique slug. (Task 5)
2. **A launcher path with spaces or a single quote** (`/Applications/My Apps/Singularity.app`): the command run and the command shown are correctly shell-quoted. (Task 2)
3. **Agent config files that are missing, empty, malformed, or list other servers only**: the row says "not connected", nothing throws, the step stays usable. (Task 2)
4. **A login shell that is slow, prints banner noise, or never returns**: the check times out, the row falls back to the copyable command, the UI never blocks. (Task 3)
5. **Renaming the placeholder Space when its folder is already on disk, when a save is still pending, or when the new slug is taken**: exactly one folder afterwards, named after the new slug (or `-2`), no data lost. (Task 5)

---

### Task 1: Live orb

**Files:**
- Create: `Sources/Singularity/Orb/OrbShader.swift` (the Metal source as a Swift string + `OrbRenderer`)
- Create: `Sources/Singularity/Orb/OrbView.swift` (SwiftUI view, `MTKView` wrapper, PNG fallback)
- Modify: `Sources/Singularity/App/MainView.swift` (the `ContentArea` placeholder uses `OrbView`)
- Create: `Tests/SingularityAppTests/OrbTests.swift`, `Tests/SingularityAppTests/Fixtures/orb-white-t4.png`, `orb-black-t4.png`

**Interfaces:**
- Produces: `struct OrbView: View { init(size: CGFloat) }` — a square view of `size` points, transparent outside the sphere. Later tasks only use this.
- Produces (for the test): `enum OrbRenderer { static func image(pixels: Int, time: Float, whiteOrb: Bool, cursor: SIMD3<Float>) -> CGImage? }` — renders one frame off screen with the same pipeline the view uses.

Port `scripts/icon/render_orb.py` (`render`, `snoise`) to a Metal fragment shader line for line: same constants (camera z = 6, radius 2.2, silhouette fills 96 % of the square, default cursor (-1.5, -1.5, 0.5), the rim, fresnel and specular terms). Draw one full-view triangle; the fragment shader ray-traces the sphere, discards/returns alpha 0 outside it, and antialiases the edge over about one pixel. Uniforms: `time`, `color` (white orb = (1,1,1), black orb = (0,0,0)), `cursor`. Output is written as-is (sRGB values straight to a non-sRGB `bgra8Unorm` target), as three.js does.

- [ ] **Step 1: Make the reference images.** Run `python3 scripts/icon/render_orb.py --time 4.0 --base white --size 256 --out Tests/SingularityAppTests/Fixtures/orb-white-t4.png` and the same with `--base black`. (Needs numpy and Pillow; if missing, `python3 -m venv` in the scratch folder and install them there, not system-wide.) If the app-test target needs `exclude: ["Fixtures"]` in `Package.swift` like the Core tests, add it and read fixtures via `#filePath`.

- [ ] **Step 2: Write the failing test** in `OrbTests.swift`:

```swift
extension AppTests {
    @MainActor @Suite struct OrbTests {
        @Test(arguments: [true, false]) func matchesTheSiteShader(whiteOrb: Bool) throws {
            _ = MainRunLoopGuard.start
            let image = try #require(OrbRenderer.image(pixels: 256, time: 4.0, whiteOrb: whiteOrb,
                                                      cursor: SIMD3(-1.5, -1.5, 0.5)))
            let reference = try fixtureImage(whiteOrb ? "orb-white-t4.png" : "orb-black-t4.png")
            // Mean absolute difference per channel, 0…255, over pixels well inside the sphere
            // (the edge is antialiased differently). The port is the same maths, so it is small.
            #expect(meanDifference(image, reference, insideRadiusFraction: 0.9) < 6)
        }
        @Test func isTransparentOutsideTheSphere() throws {
            let image = try #require(OrbRenderer.image(pixels: 64, time: 0, whiteOrb: true, cursor: SIMD3(-1.5, -1.5, 0.5)))
            #expect(alpha(of: image, x: 0, y: 0) == 0)
            #expect(alpha(of: image, x: 32, y: 32) == 255)
        }
    }
}
```

`fixtureImage`, `meanDifference`, `alpha` are small helpers in the same file. If no Metal device is available (`MTLCreateSystemDefaultDevice() == nil`), `image` returns nil and the test is skipped with a recorded note, not failed.

- [ ] **Step 3: Run it; expect a compile failure** (`OrbRenderer` unknown): `source scripts/env.sh && swift test --filter OrbTests`.

- [ ] **Step 4: Implement `OrbShader.swift`.** `OrbRenderer` compiles the source once with `device.makeLibrary(source:options:)`, caches the pipeline state, and has `draw(into:time:whiteOrb:cursor:)` used by both the off-screen `image(...)` and the view. If the threshold of 6 cannot be met, find the porting mistake; do not raise the threshold past 10 without writing why in the test.

- [ ] **Step 5: Implement `OrbView.swift`.**
  - `MTKView` in an `NSViewRepresentable`, `layer.isOpaque = false`, clear colour transparent, `preferredFramesPerSecond = 30`.
  - Colour: white orb in dark appearance, black in light (`@Environment(\.colorScheme)`), as the static image does today.
  - Pointer: an `NSTrackingArea`; while the pointer is over the sphere, the target cursor is the unit vector from the sphere's centre to the hit point (view space, as the site does); each frame `cursor += (target - cursor) * 0.1`.
  - Energy: `isPaused = true` unless the view is in a window that is visible and not occluded (`NSWindow.didChangeOcclusionStateNotification`, `viewDidMoveToWindow`), and when the app is hidden.
  - Reduce motion (`@Environment(\.accessibilityReduceMotion)`): draw one frame at time 4.0 and stay paused.
  - Fallback: if there is no Metal device or the shader fails to compile, show `Orb-dark.png`/`Orb-light.png` from the bundle exactly as `ContentArea` does now; if that is missing too, show nothing.

- [ ] **Step 6: Use it** in `ContentArea` (`MainView.swift`): replace the `Image(nsImage: orb)` block with `OrbView(size: 96).padding(.bottom, 8)`. Keep the Space name and the hint line.

- [ ] **Step 7: Run** `swift test --filter OrbTests` → PASS, then `scripts/test.sh` → all pass.

- [ ] **Step 8: Look at it.** `rm -rf /private/tmp/sg-test && SINGULARITY_HOME=/private/tmp/sg-test .build/out/Products/Debug/Singularity &` then take a screenshot of that window (`screencapture -l <window id>`, or the whole screen if that is simpler) and check: orb animates, ripples follow the pointer, edge is clean, background shows through. Check Activity Monitor-style CPU with `ps -o %cpu -p <pid>` after 10 s idle: under 10 %. Quit that copy only (`kill <pid>`).

- [ ] **Step 9: Commit** — `Live orb: the site's shader in Metal, in place of the static image`.

---

### Task 2: Agent connection logic (Core)

**Files:**
- Create: `Sources/SingularityCore/Agent/AgentConnect.swift`
- Test: `Tests/SingularityCoreTests/AgentConnectTests.swift`

**Interfaces — Produces:**

```swift
public enum AgentKind: String, CaseIterable, Sendable {
    case claudeCode, codex
    public var title: String        // "Claude Code", "Codex"
    public var program: String      // "claude", "codex"
}

public enum AgentConnect {
    /// POSIX single-quote quoting: abc → 'abc', it's → 'it'\''s'.
    public static func shellQuote(_ text: String) -> String
    /// True for a path macOS made by translocation (contains "/AppTranslocation/").
    public static func isTranslocated(_ launcherPath: String) -> Bool
    /// claude: `claude mcp add -s user singularity -- '<launcher>'`
    /// codex:  `codex mcp add singularity -- '<launcher>'`
    public static func addCommand(_ agent: AgentKind, launcher: String) -> String
    /// claude: `claude mcp remove -s user singularity`; codex: `codex mcp remove singularity`
    public static func removeCommand(_ agent: AgentKind) -> String
    /// `command -v <program>` (run through the login shell; exit 0 = installed).
    public static func findCommand(_ agent: AgentKind) -> String
    /// The config file that holds the user-wide entry: ~/.claude.json, ~/.codex/config.toml.
    public static func configFile(_ agent: AgentKind, home: URL) -> URL
    /// The command registered for the server named "singularity", or nil when there is none
    /// or the text can't be read as expected. Never throws.
    public static func registeredLauncher(_ agent: AgentKind, configText: String) -> String?
    /// Combines the facts into what the row shows.
    public static func status(installed: Bool, registered: String?, launcher: String) -> AgentConnectStatus
}

public enum AgentConnectStatus: Equatable, Sendable {
    case translocated          // app runs from a temporary path: no button
    case notInstalled          // agent not found: show the command to copy
    case notConnected          // Connect button
    case connected             // registered == launcher
    case otherCopy(String)     // registered elsewhere (the path): Update button
}
```

Rules: `status` returns `.translocated` first when `isTranslocated(launcher)`; a registered entry is reported even when the agent is not found (`.connected`/`.otherCopy` win over `.notInstalled`). Paths are compared after `URL(fileURLWithPath:).standardizedFileURL.path`.

`registeredLauncher`:
- Claude: parse JSON; the value is top-level `mcpServers.singularity.command` (a string). Entries under `projects.<path>.mcpServers` are ignored.
- Codex: a small line scanner, not a TOML library: find the table header `[mcp_servers.singularity]` (also `[mcp_servers."singularity"]`), then the first `command = "…"` or `command = '…'` line before the next `[` header; unescape `\"` and `\\` in double-quoted strings. Also accept the inline form `singularity = { command = "…", … }` under `[mcp_servers]`.

- [ ] **Step 1: Write the failing tests** (`@Suite struct AgentConnectTests`), with these cases and exact values:
  - `shellQuote("/Applications/Singularity.app/x") == "'/Applications/Singularity.app/x'"`; `shellQuote("/A p/it's") == "'/A p/it'\\''s'"`.
  - `addCommand(.claudeCode, launcher: "/Applications/My Apps/Singularity.app/Contents/MacOS/singularity-mcp") == "claude mcp add -s user singularity -- '/Applications/My Apps/Singularity.app/Contents/MacOS/singularity-mcp'"`; codex: `"codex mcp add singularity -- '…'"`.
  - `removeCommand` both; `findCommand(.codex) == "command -v codex"`.
  - `isTranslocated("/private/var/folders/ab/T/AppTranslocation/1234/d/Singularity.app/Contents/MacOS/singularity-mcp") == true`; `/Applications/…` false.
  - Claude config: user entry found; only a `projects` entry → nil; `""`, `"{"`, `"[]"`, `{"mcpServers":{"other":{"command":"x"}}}`, `{"mcpServers":{"singularity":{"type":"http","url":"u"}}}` → nil.
  - Codex config: table form with double quotes, with single quotes, with a comment line and another server before it, inline form, a file with only `[mcp_servers.other]` → nil, empty → nil, `command` appearing only under a later table → nil.
  - `status`: translocated wins; `(installed: false, registered: nil)` → `.notInstalled`; `(true, nil)` → `.notConnected`; `(true, launcher)` → `.connected`; `(true, "/other/singularity-mcp")` → `.otherCopy("/other/singularity-mcp")`; `(false, launcher)` → `.connected`; `/Applications/./Singularity.app/…` equals `/Applications/Singularity.app/…`.
- [ ] **Step 2: Run** `source scripts/env.sh && swift test --filter AgentConnectTests` → compile failure.
- [ ] **Step 3: Implement `AgentConnect.swift`.**
- [ ] **Step 4: Run** the filter → PASS.
- [ ] **Step 5: Commit** — `Agents: commands and config reading for connecting Claude Code and Codex (Core)`.

---

### Task 3: Connect rows in the app, and in Settings → Agents

**Files:**
- Create: `Sources/Singularity/Agent/AgentConnector.swift`
- Create: `Sources/Singularity/Agent/AgentConnectRows.swift`
- Modify: `Sources/Singularity/Settings/SettingsView.swift` (`AgentSettings`: the "Connect Claude Code" section becomes "Connect agents" using `AgentConnectRows`; remove `registerCommand`/`copied`, keep the "isn't in /Applications" note)
- Test: `Tests/SingularityAppTests/AgentConnectorTests.swift`

**Interfaces:**
- Consumes: everything from Task 2; `CommandBroker.run(path:arguments:timeout:environment:currentDirectory:children:) async -> CommandResult` (Core; read `CommandResult`'s fields in `CommandBroker.swift`).
- Produces:

```swift
/// Runs one command line the way a terminal tab would see it. Tests pass a fake.
protocol AgentShell: Sendable {
    func run(_ commandLine: String) async -> (exitCode: Int32, output: String, timedOut: Bool)
}
/// The user's login shell: `$SHELL -l -i -c <commandLine>`, cwd = home, stdin = /dev/null, 20 s timeout.
struct LoginShell: AgentShell

@MainActor @Observable final class AgentConnector {
    enum RowState: Equatable {
        case checking
        case status(AgentConnectStatus)
        case working                     // Connect/Update running
        case failed(String)              // the program's error text, trimmed, max 300 characters
    }
    private(set) var rows: [AgentKind: RowState]
    let launcher: String
    init(launcher: String, home: URL = FileManager.default.homeDirectoryForCurrentUser, shell: AgentShell = LoginShell())
    func refresh() async                 // checks both agents, concurrently
    func connect(_ agent: AgentKind) async   // add; for .otherCopy: remove, then add; then re-check
    func command(for agent: AgentKind) -> String   // the copyable command (AgentConnect.addCommand)
}

/// One row per agent, per the spec's state table. Used by the welcome flow and by Settings.
struct AgentConnectRows: View { init(connector: AgentConnector) }
```

Behaviour to pin:
- `refresh` reads the config file (missing/unreadable = no entry), asks the shell `findCommand`, and sets `.status(AgentConnect.status(...))`. A timed-out or failing `command -v` means "not installed".
- `connect` sets `.working`, runs the command(s); on non-zero exit or timeout → `.failed(text)`; otherwise re-reads the config and shows the resulting status (what the check says, not what was hoped for). If the re-read still says not connected → `.failed("The agent did not keep the entry.")`.
- `connect` does nothing when the launcher is translocated.
- Rows (spec table): checking = small `ProgressView`; notInstalled = "Not found" + command with Copy; notConnected = "Connect" + caption "Adds Singularity to ‹title›'s MCP servers"; connected = "Connected ✓" (green); otherCopy = "Points at another copy of Singularity" + "Update"; failed = error text (red) + command with Copy; translocated = "Move Singularity to the Applications folder and reopen it".
- `LoginShell`: `$SHELL` from the environment, else the user's shell from `getpwuid`, else `/bin/zsh`. An interactive shell without a terminal may print warnings: use only the exit code for `command -v`, and for add/remove show the combined output on failure.

- [ ] **Step 1: Write the failing tests** with a `FakeShell` (records command lines, returns scripted results) and a temp `home`:
  - both agents installed, no config files → both `.status(.notConnected)`; the shell was asked `command -v claude` and `command -v codex`.
  - `~/.claude.json` in the temp home naming this launcher → `.status(.connected)`.
  - `connect(.codex)` with a fake that writes the entry into the temp `config.toml` when it sees the add command → `.status(.connected)`, and the recorded line equals `AgentConnect.addCommand(.codex, launcher:)`.
  - `connect` on `.otherCopy` → recorded lines are remove then add, in that order.
  - add exits 1 with output "boom" → `.failed("boom")`.
  - add exits 0 but the file is unchanged → `.failed("The agent did not keep the entry.")`.
  - shell times out on `command -v` → `.status(.notInstalled)`.
  - translocated launcher → `.status(.translocated)` and `connect` records no command.
- [ ] **Step 2: Run** `swift test --filter AgentConnectorTests` → compile failure.
- [ ] **Step 3: Implement `AgentConnector.swift`** (with `LoginShell`).
- [ ] **Step 4: Run** the filter → PASS.
- [ ] **Step 5: Implement `AgentConnectRows.swift`** and switch `AgentSettings` to it (`@State private var connector = AgentConnector(launcher: …)`, `.task { await connector.refresh() }`).
- [ ] **Step 6: Check by hand, read-only.** Run the debug binary with `SINGULARITY_HOME=/private/tmp/sg-test`, open Settings → Agents (⌘,), screenshot. Expected on this Mac: Claude Code "Points at another copy of Singularity" (the real config points at `build/Singularity.app`), Codex "Connect". **Do not click Connect or Update.** Quit that copy.
- [ ] **Step 7: Run** `scripts/test.sh` → all pass. **Commit** — `Agents: Connect buttons for Claude Code and Codex in Settings`.

---

### Task 4: Plugins shipped inside the app

**Files:**
- Create: `Sources/SingularityCore/Plugins/BundledPlugins.swift`
- Test: `Tests/SingularityCoreTests/BundledPluginsTests.swift`
- Modify: `scripts/build-app.sh`, `scripts/release.sh` (copy step, next to the `plugin-host` copy)

**Interfaces — Produces:**

```swift
public struct BundledPlugin: Equatable, Identifiable, Sendable {
    public let id: String, name: String, summary: String   // summary = manifest description
    public let folder: URL
}
public enum BundledPlugins {
    /// `<app>/Contents/Resources/Plugins`
    public static func pluginsFolder(resources: URL) -> URL
    /// `<app>/Contents/Resources/plugin-guide` (holds AUTHORING.md and template/)
    public static func guideFolder(resources: URL) -> URL
    /// Valid plugins in `folder`, sorted by name. A missing folder or a broken plugin is skipped.
    public static func list(in folder: URL) -> [BundledPlugin]
    /// The prompt the user copies into their agent.
    public static func authoringPrompt(guide: URL, pluginsDirectory: URL) -> String
}
```

`authoringPrompt` returns exactly (with `~` for the home folder in `pluginsDirectory`, the guide path in full):

```
Read <guide>/AUTHORING.md (a template is in <guide>/template), then write a Singularity plugin in <pluginsDirectory>/<id> that …
```

Bundle layout: `Contents/Resources/Plugins/1password/…` (every folder of the repo's `Plugins/` except `template`), `Contents/Resources/plugin-guide/AUTHORING.md` (from `docs/plugins/AUTHORING.md`) and `Contents/Resources/plugin-guide/template/` (from `Plugins/template`). No `node_modules`, no `.git`, no `.DS_Store` is copied.

- [ ] **Step 1: Write the failing tests** using temp folders: two valid plugin folders listed sorted by name with id/name/summary from the manifests (use `Plugins/1password/plugin.json` via `#filePath` for one of them and assert `name == "1Password"`, `summary == "Fill logins from 1Password, unlocked with Touch ID."`); a folder with broken JSON is skipped; a missing folder → `[]`; a plain file in the folder is skipped; `authoringPrompt(guide: URL(fileURLWithPath: "/Applications/Singularity.app/Contents/Resources/plugin-guide"), pluginsDirectory: <home>/Singularity/plugins)` equals the exact string above with `~/Singularity/plugins`.
- [ ] **Step 2: Run** `swift test --filter BundledPluginsTests` → compile failure.
- [ ] **Step 3: Implement** (reuse `PluginManifest.load(from:)`; a manifest whose only problem is a folder/id mismatch is still skipped: bundled folders are named after their ids).
- [ ] **Step 4: Run** the filter → PASS.
- [ ] **Step 5: Build scripts.** Add the copy to both scripts. Verify: `APP=/private/tmp/sg-app/Singularity.app scripts/build-app.sh`, then `ls /private/tmp/sg-app/Singularity.app/Contents/Resources/Plugins /private/tmp/sg-app/Singularity.app/Contents/Resources/plugin-guide` shows `1password`, and `AUTHORING.md  template`; `codesign --verify --deep --strict /private/tmp/sg-app/Singularity.app` exits 0. (`release.sh` is changed the same way and checked by reading; do not run it.)
- [ ] **Step 6: Commit** — `Plugins: ship the ready-made plugins and the authoring guide inside the app`.

---

### Task 5: Onboarding logic and state

**Files:**
- Create: `Sources/SingularityCore/Onboarding/Onboarding.swift`
- Test: `Tests/SingularityCoreTests/OnboardingTests.swift`
- Modify: `Sources/SingularityCore/Persistence/SpaceStore.swift` (`moveSpaceFolder`), `Sources/SingularityCore/Model/Space.swift` (the `slug` doc comment names the one exception)
- Modify: `Sources/Singularity/App/AppState.swift`
- Test: `Tests/SingularityCoreTests/CoreTests.swift` or a new file for `moveSpaceFolder`

**Interfaces — Produces (Core):**

```swift
public enum OnboardingStep: Int, CaseIterable, Sendable { case welcome, space, agents, plugins }

public struct OnboardingFlow: Equatable, Sendable {
    public private(set) var step: OnboardingStep = .welcome
    /// True once Spaces were imported from Arc in this flow: the Space step is left out.
    public private(set) var importedFromArc = false
    public init()
    public var canGoBack: Bool                 // false on .welcome
    /// The next step, or nil when the flow is finished (after .plugins).
    public mutating func advance() -> OnboardingStep?
    public mutating func back()                // .agents → .space, or → .welcome after an Arc import
    public mutating func arcImportFinished()   // importedFromArc = true; step = .agents
}

public enum FirstRun {
    /// A brand-new install: nothing was loaded and nothing failed to load.
    public static func isBrandNew(loadedSpaceCount: Int, loadErrorCount: Int) -> Bool
    /// The one case where a Space's slug may follow its name (spec, step 2).
    public static func mayReslug(isFirstRunPlaceholder: Bool, tabCount: Int) -> Bool
}

extension SpaceStore {
    /// Renames a Space's folder. Does nothing (and succeeds) when the old folder doesn't exist
    /// yet; throws when the new one already exists.
    public func moveSpaceFolder(fromSlug: String, toSlug: String) throws
}
```

**Interfaces — Produces (`AppState`):**

```swift
/// Non-nil while the welcome flow covers the window.
private(set) var onboarding: OnboardingFlow?
/// The Space made at a brand-new install's first launch, until the flow ends or it gets a tab.
private(set) var firstRunPlaceholderID: UUID?

func showWelcome()                               // onboarding = OnboardingFlow(); palette = nil
func closeWelcome()                              // onboarding = nil; firstRunPlaceholderID = nil
func advanceWelcome()                            // flow.advance(); nil → closeWelcome()
func welcomeBack()
/// The Space step 2 edits: the placeholder on a brand-new install, else the selected Space.
var welcomeSpace: Space? { get }
/// Step 2's Continue. Saves the three fields; re-slugs when FirstRun.mayReslug allows.
func applyWelcomeSpace(name: String, colorHex: String, workingDirectory: String)
/// Sets only `agentsEnabled` (policy untouched), same effects as `updateSpace`.
func setAgentsEnabled(_ on: Bool, spaceID: UUID)
```

Changes inside `AppState`:
- `init`: where the first Space is created (`if spaces.isEmpty`), compute `FirstRun.isBrandNew(loadedSpaceCount: loaded.spaces.count, loadErrorCount: loaded.errors.count)`; when true, remember the new Space's id in `firstRunPlaceholderID` and set `onboarding = OnboardingFlow()`.
- `importArcSpaces`: after adding the Spaces, if `onboarding != nil`: when `firstRunPlaceholderID` names a Space with no tabs, delete it with `deleteSpace` (there is more than one Space now), clear the id; then `onboarding?.arcImportFinished()`.
- Commands that take the user somewhere close the flow first: `showPalette`, `openTerminal`, `selectSpace` (only when called by the user, i.e. not from `createSpace`/import during the flow — pass that distinction however is cleanest), `openInNewTab`, `openArtifact`, and setting `spaceEditor` from the menu/palette.
- `applyWelcomeSpace` re-slug: new slug = `Slug.unique(from: name, existing: <other Spaces' slugs> ∪ <slugs on disk> − <this Space's current slug>)`. If it differs from the current slug: flush pending saves, `store.moveSpaceFolder`, change `slug`, drop caches keyed by the old slug if any exist (read how `artifacts`, `favicons`, `historyCache` key things: by id or by slug; anything slug-keyed must follow), mark dirty, save. If the move throws, keep the old slug and still save the other fields.
- `setAgentsEnabled` is then also used by Settings → Agents' `enabledBinding` if that makes the code simpler; otherwise leave Settings alone.

- [ ] **Step 1: Write the failing Core tests:**
  - flow: starts at `.welcome`, `canGoBack == false`; `advance()` yields `.space`, `.agents`, `.plugins`, then `nil`; `back()` from `.agents` → `.space`; after `arcImportFinished()` the step is `.agents`, `back()` → `.welcome`, and a later `advance()` from `.welcome` goes to `.agents` (skips `.space`).
  - `isBrandNew(0, 0) == true`, `(0, 1) == false`, `(1, 0) == false`.
  - `mayReslug(true, 0) == true`, `(true, 1) == false`, `(false, 0) == false`.
  - `moveSpaceFolder`: saved Space "personal" moved to "work" → `spaces/work/space.json` exists, `spaces/personal` gone; old folder missing → no throw, nothing created; target exists → throws and both folders are untouched.
  - Slugs (Review Focus 1): `Slug.unique(from: "🎉", existing: [])` is non-empty and contains only `a-z0-9-` (if `Slug.make` returns "" today, fix it to fall back to `"space"`); `Slug.unique(from: "Work", existing: ["work"]) == "work-2"`.
- [ ] **Step 2: Run** `swift test --filter OnboardingTests` → compile failure. **Step 3: Implement Core.** **Step 4: Run** → PASS.
- [ ] **Step 5: Implement the `AppState` changes.**
- [ ] **Step 6: App-level test** (`Tests/SingularityAppTests/OnboardingStateTests.swift`), only if `AppState` can be built in a test with a temp data folder (look for how/whether existing app tests construct it and for the `SINGULARITY_HOME` override in `Paths`); if it cannot without large changes, skip this step and say so in the commit body. Cases: fresh folder → `onboarding != nil`, one Space, `firstRunPlaceholderID` set; `applyWelcomeSpace(name: "Work", …)` → the Space's slug is `work`, and after `flushSaves()` only `spaces/work` exists (Review Focus 5: also when `flushSaves()` ran *before* the rename, so `spaces/personal` was already on disk); a second `AppState` on the same folder → `onboarding == nil`; `setAgentsEnabled(true, …)` leaves `agentPolicy == .ask`.
- [ ] **Step 7: Run** `scripts/test.sh` → all pass. **Commit** — `Onboarding: first-run detection, step sequence, and the one-time slug rename`.

---

### Task 6: The welcome flow

**Files:**
- Create: `Sources/Singularity/Onboarding/OnboardingView.swift` (frame: orb side, footer with dots/Back/Skip setup/primary; switches on `state.onboarding?.step`)
- Create: `Sources/Singularity/Onboarding/OnboardingSteps.swift` (`WelcomeStep`, `SpaceStep`, `AgentsStep`, `PluginsStep`)
- Create: `Sources/Singularity/Sidebar/SpaceFields.swift` (name, colour, terminal folder controls extracted from `SpaceEditorSheet`, which then uses them)
- Modify: `Sources/Singularity/Sidebar/SpaceEditorSheet.swift`, `Sources/Singularity/App/MainView.swift`, `Sources/Singularity/App/Commands.swift`, `Sources/Singularity/Palette/PaletteItem.swift`

**Interfaces — Consumes:** `OrbView(size:)` (Task 1); `AgentConnector`, `AgentConnectRows` (Task 3); `BundledPlugins`, `BundledPlugin` (Task 4); `state.onboarding`, `showWelcome`, `closeWelcome`, `advanceWelcome`, `welcomeBack`, `welcomeSpace`, `applyWelcomeSpace`, `setAgentsEnabled` (Task 5); existing `state.isImportingFromArc`, `ArcImport.defaultFile`, `state.plugins.addPlugin(from:) async throws -> String`, `state.plugins.plugin(_:)`, `InstalledPlugin.needsReview`, `PluginApprovalSheet(pluginID:currentSpaceID:)`.

**Produces:** `struct SpaceFields: View { init(name: Binding<String>, colorHex: Binding<String>, workingDirectory: Binding<String>) }`.

What to build (wording and layout from the spec's "The four steps"; the mockup's proportions: orb side about 40 % of the width):
- `MainView`: when `state.onboarding != nil`, show `OnboardingView()` instead of the `HStack` (sidebar + content); the palette overlay and the sheets stay attached, so the Arc sheet and approval sheet work over the flow. Background: the window's normal material.
- Orb: `OrbView(size: 220)` on step 1, `OrbView(size: 150)` after, animated size change.
- Footer on every step: step dots (three dots after an Arc import), "Back" when `canGoBack`, a quiet "Skip setup" (plain, secondary colour) → `closeWelcome()`, the primary button with `.keyboardShortcut(.defaultAction)`. Esc → `closeWelcome()` (`.onExitCommand` or a hidden cancel-action button).
- Step 1: title, text, "Get started" → `advanceWelcome()`; "Import from Arc…" only when `FileManager.default.fileExists(atPath: ArcImport.defaultFile.path)` → `state.isImportingFromArc = true` (Task 5 moves the flow on after the import).
- Step 2: `SpaceFields` bound to local state initialised from `state.welcomeSpace`; "Continue" disabled while the trimmed name is empty → `applyWelcomeSpace(...)` then `advanceWelcome()`; "Skip" → `advanceWelcome()` without saving.
- Step 3: `AgentConnectRows(connector:)` with `.task { await connector.refresh() }` (the check runs when the step appears); then one switch per Space in `state.spaces`: "Let agents use ‹name›", caption "They ask before clicking or typing", bound to `agentsEnabled` via `setAgentsEnabled`. "Skip" and "Continue" both → `advanceWelcome()`.
- Step 4: `BundledPlugins.list(in: BundledPlugins.pluginsFolder(resources: Bundle.main.resourceURL!))`; each row name + summary + a button: not installed → "Add" (`try await state.plugins.addPlugin(from: plugin.folder)`, then present `PluginApprovalSheet` for the returned id); installed and `needsReview` → "Review…" (presents the sheet); installed and approved → "Added" (plain text). An add error shows its `userMessage` under the row. An empty list (bare debug binary) shows nothing in place of the list. Below: "Or have your agent write one:", the `authoringPrompt` in a monospaced box with "Copy". Primary "Start browsing" → `advanceWelcome()` (ends the flow).
- Menu: `CommandGroup(after: .appInfo) { Button("Welcome to Singularity…") { state.showWelcome() } }`. Palette: `command("welcome", "Welcome to Singularity…", "sparkle") { state.showWelcome() }`.
- Minimum window size must still fit the flow; if the window is narrower than about 720 points, hide the orb side rather than clip the controls.

- [ ] **Step 1: Extract `SpaceFields`** and use it in `SpaceEditorSheet`; `swift build`; the sheet looks and behaves as before (open Edit Space in the test copy, screenshot).
- [ ] **Step 2: Build `OnboardingView` and the four steps**, `MainView` switch, menu and palette entries.
- [ ] **Step 3: App test** `Tests/SingularityAppTests/OnboardingViewTests.swift`, if Task 5's step 6 found `AppState` constructible: host `OnboardingView` in an off-screen window with a fresh-folder `AppState`; assert it lays out at 1100×720 and at 700×500 without throwing, and that after `state.advanceWelcome()` four times `state.onboarding == nil`. Otherwise skip, and say so in the commit body.
- [ ] **Step 4: Walk through it for real** with a full bundle (the plugin step needs it): `APP=/private/tmp/sg-app/Singularity.app scripts/build-app.sh`, `rm -rf /private/tmp/sg-test`, run `/private/tmp/sg-app/Singularity.app/Contents/MacOS/Singularity` with `SINGULARITY_HOME=/private/tmp/sg-test`. Screenshot each step. Check, and fix what fails:
  1. the flow shows at launch; the orb animates;
  2. step 2: name "Work", another colour → Continue; afterwards `ls /private/tmp/sg-test/spaces` shows only `work`;
  3. step 3: rows show a state for both agents; the Space switch is **off**; **do not click Connect/Update**;
  4. step 4: 1Password row with "Add"; click it → the approval sheet appears; cancel it → the row says "Review…"; Copy puts the prompt on the pasteboard (`pbpaste`);
  5. "Start browsing" → the normal window, Space "Work", empty-Space orb;
  6. quit, start again → no flow; app menu → "Welcome to Singularity…" → the flow, step 2 shows "Work"; Esc closes it;
  7. `rm -rf /private/tmp/sg-test`, start, press ⌘T on step 1 → the flow closes and the palette opens.
  Driving clicks: use `osascript`/System Events accessibility if available; if it is not permitted in this environment, verify what can be verified by screenshots and the app tests, and list in the commit body exactly which of the seven checks were not exercised.
- [ ] **Step 5: Run** `scripts/test.sh` → all pass. **Commit** — `Onboarding: the welcome flow (Space, agents, plugins), menu and palette entries`.

---

### Task 7: Documentation

**Files:** Modify `CLAUDE.md`, `README.md`, `IDEAS.md`, `docs/superpowers/specs/2026-11-11-onboarding-design.md`.

- [ ] **Step 1: `CLAUDE.md`**: architecture tree gains `Onboarding/` (Core and app), `Orb/`, `Agent/AgentConnect` (Core), `AgentConnector`/`AgentConnectRows`, `BundledPlugins`; a "Key decisions" bullet **Onboarding** (when it shows, no stored flag, the one-time slug exception, Connect reads config files and never starts a server, agents switch off by default, bundled plugins + guide in `Contents/Resources`, the orb is a run-time compiled Metal shader with PNG fallback, paused when not visible); the icon bullet no longer says empty tabs show `Orb-*.png` (they are the fallback now). Add to the build notes: never run real `claude mcp`/`codex mcp` add/remove in tests.
- [ ] **Step 2: `README.md`**: the agent section mentions the Connect buttons (welcome flow and Settings → Agents) before the manual command; add the Codex command.
- [ ] **Step 3: `IDEAS.md`**: remove the onboarding item (finished items are removed); the Claude Chat item stays and becomes first.
- [ ] **Step 4: Spec**: status line → "built on <date>", plus an "As built" section listing every place the build differs from the design, and any of Task 6's seven checks that could not be exercised.
- [ ] **Step 5: Run** `scripts/test.sh` one last time → all pass. **Commit** — `Onboarding: docs`.
