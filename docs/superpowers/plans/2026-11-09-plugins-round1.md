# Singularity Plugins, Round 1: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task by task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a plugin system that can install, approve, sandbox and run TypeScript plugins, plus a 1Password plugin that fills logins on github.com/login after a Touch ID unlock.

**Architecture:** The logic lives in `SingularityCore`, where it can be unit-tested: the manifest, its validation, approval fingerprints, command rules, the sandbox profile, and the Bun process with its line-based JSON protocol. The app target adds:
- discovery and the plugin manager;
- Settings → Plugins with an approval sheet;
- the page bridge: a `WKContentWorld` per plugin, plus a prelude script with UI and fill helpers.

Plugins run on a bundled Bun under `sandbox-exec`. They can only reach the outside through Singularity: messages from their page script, commands run by Singularity, and fills.

**Tech Stack:** Swift 6 / SwiftUI / WebKit (existing), Swift Testing, bundled Bun (TypeScript runtime, owner-approved dependency), `sandbox-exec`, 1Password CLI `op` (on the user's Mac).

**Spec:** `docs/superpowers/specs/2026-11-09-plugins-design.md` (approved 2026-11-09). Read it before any task.

## Global Constraints

- **Branches:** start from `main` *after* the `settings` branch is merged; this plan adds a Plugins tab to its Settings window. Work on branch `plugins-round1`.
- **Platform:** macOS 14+; WKWebView only; no extension APIs (`WKWebExtension`) anywhere.
- **Runtime:** Bun, bundled inside the app at a pinned version, never downloaded at runtime. It's fetched by a build script that verifies a pinned SHA-256.
- **Signing:** team `T748B76PPL` signs everything, Bun included. `scripts/release.sh` must still produce a notarizable app.
- **Data locations:**
  - plugins: `~/Singularity/plugins/<id>/`;
  - plugin data: `~/Singularity/plugins-data/<id>/`;
  - approvals: `~/Singularity/plugins-state.json`.
- **Plugin ids:** `^[a-z0-9][a-z0-9-]{0,39}$`, equal to the folder name.
- **Round-1 permissions** are exactly `pageAdditions`, `fillForms`, `commands`, `network`. Any other key is an error. `network` must be empty in round 1.
- **Refused command names:** `sh bash zsh fish dash ksh csh tcsh env sudo su curl wget ssh scp sftp nc ncat telnet ftp rsync osascript open python python3 perl ruby php node bun deno npx bunx`.
- **npm packages:** `package.json` with dependencies requires `bun.lock`. Install with `bun install --frozen-lockfile --ignore-scripts`, run by Singularity at approval, never in the sandbox.
- **Never:** plugins can't reach cookies or website data, can't use the network in round 1, and can't run any program or argument beyond what the manifest declares.
- **Style:** boring, commented Swift (see CLAUDE.md); new Core code gets Swift Testing tests run by `scripts/test.sh`.

## Review Focus

1. **A plugin whose background crashes or has a syntax error.** Expect: Settings shows the error and the last log lines, and Singularity restarts it at most 3 times per minute, then stops with "crashed repeatedly". No busy loop. Test in Task 6 (`restartBackoffStopsAfterThreeCrashes`).
2. **1Password not signed in, Touch ID cancelled, or the 1Password app closed.** Expect: the menu shows "1Password is locked or unavailable" within the command timeout (60 s), with nothing hanging. Test in Task 10 (manual checklist item 3) and Task 5 (`runTimesOutAndReportsIt`).
3. **Login forms that re-render** (single-page apps) or appear late. Expect: the button reattaches after DOM changes, and there's never more than one button per field. Test in Task 8 (fixture page `relogin.html` with a form replaced after 1 s).
4. **Enabling or disabling a plugin for a Space while its tabs are open.** Expect: open tabs gain or lose the page script without a relaunch, and other Spaces are never affected. Test in Task 8 (manual step 4 plus the `PluginScripts.rebuild` unit test).
5. **A plugin folder edited by an agent while development mode is off.** Expect: the plugin pauses with status "changed since you approved it" and nothing new runs. Test in Task 4 (`changedFilesPauseWithoutDevelopmentMode`).

---

### Task 1: Bundle Bun and prove the sandbox works

**Files:**
- Create: `scripts/fetch-bun.sh`, `Resources/Bun.entitlements`, `Vendor/.gitignore` (ignores `bun/`)
- Modify: `scripts/build-app.sh`, `scripts/release.sh` (copy and sign `Contents/Helpers/bun`), `CLAUDE.md` (Bun note)

**Interfaces:**
- Produces: the bundled runtime at `Singularity.app/Contents/Helpers/bun`; at development time, `Vendor/bun/bun` (a universal binary).

- [ ] **Step 1:** Write `scripts/fetch-bun.sh`.
  - It pins `BUN_VERSION` to the newest `bun-v1.*` tag on the day of implementation; look it up with `git ls-remote --tags https://github.com/oven-sh/bun`.
  - It downloads `bun-darwin-aarch64.zip` and `bun-darwin-x64.zip` from that release and checks each against a SHA-256 pinned in the script; on a mismatch it stops.
  - It runs `lipo -create` into `Vendor/bun/bun`, and does nothing if that version is already there.
- [ ] **Step 2:** Run `scripts/fetch-bun.sh && Vendor/bun/bun --version && lipo -archs Vendor/bun/bun`. Expected: the pinned version, and `x86_64 arm64`.
- [ ] **Step 3:** `Resources/Bun.entitlements` gets `com.apple.security.cs.allow-jit` and `com.apple.security.cs.allow-unsigned-executable-memory` (JavaScriptCore needs both under the hardened runtime). `build-app.sh` and `release.sh` copy `Vendor/bun/bun` to `Contents/Helpers/bun` and sign it with these entitlements *before* signing the app. `build-app.sh` calls `fetch-bun.sh` first.
- [ ] **Step 4:** Check the sandbox by hand, in a scratch folder with `x.ts` (`console.log("ok", 1 as number); await fetch("https://example.com")`) and a profile from the template in Task 4 (deny network, allow the folder):
  `sandbox-exec -p "$(cat profile.sb)" build/Singularity.app/Contents/Helpers/bun run x.ts`.
  Expected: it prints `ok 1`, then the fetch fails with a network error. **If Bun can't start under the profile, stop and report** (spec risk 2).
- [ ] **Step 4b (spec risk 3, an early check for round 2):** in a scratch folder, `Vendor/bun/bun add @anthropic-ai/claude-agent-sdk` and a 5-line `check.ts` that imports it and prints its exported names; run it with `Vendor/bun/bun run check.ts`. Expected: it imports under Bun. Record the outcome in the PR; this task doesn't depend on it.
- [ ] **Step 5:** `scripts/release.sh --skip-notarize`. Expected: `codesign --verify --deep --strict` passes with Bun inside, `TeamIdentifier=T748B76PPL`.
- [ ] **Step 6:** Commit: `git commit -m "Bundle Bun runtime (pinned, verified) and sign it with JIT entitlements"`.

### Task 2: Site patterns and host matching (Core)

**Files:**
- Create: `Sources/SingularityCore/Plugins/SitePattern.swift`, `Tests/SingularityCoreTests/PluginTests.swift`

**Interfaces:**
- Produces:
  - `public struct SitePattern: Hashable, Sendable { public let text: String; public init(_ text: String) throws(PluginError); public func matches(_ url: URL) -> Bool }`
  - `public enum HostMatch { public static func isSameOrSubdomain(_ host: String, of savedHost: String) -> Bool }`
  - `public enum PluginError` (defined here, extended in Task 3) with `case invalidSitePattern(String)`.

- [ ] **Step 1:** Write the tests `sitePatterns` and `hostMatching`:
  - `<all_urls>` matches `https://a.com/x` and `http://b.org`, but not `about:blank`.
  - `https://*.github.com/*` matches `https://github.com/login` and `https://gist.github.com/x`, but not `http://github.com/` and not `https://evilgithub.com/`.
  - `*://example.com/*` matches http and https.
  - `ftp://x/*`, `https://exa*mple.com/*` and the empty string throw `invalidSitePattern`.
  - `isSameOrSubdomain("www.github.com", of: "github.com")` is true; `("github.com", of: "www.github.com")` is false; `("evilgithub.com", of: "github.com")` is false.
  - Comparison is case-insensitive, and a trailing dot is ignored.
- [ ] **Step 2:** `scripts/test.sh --filter PluginTests`. Expected: FAIL (types not defined).
- [ ] **Step 3:** Implement the Chrome match-pattern subset: scheme `*|http|https`, host `*`, `*.domain` or an exact name, and a path with `*` wildcards. That's enough for round 1.
- [ ] **Step 4:** Run the tests. Expected: PASS.
- [ ] **Step 5:** Commit: `git commit -m "Plugins: site patterns and host matching"`.

### Task 3: Manifest, validation and command rules (Core)

**Files:**
- Create: `Sources/SingularityCore/Plugins/PluginManifest.swift`, `Sources/SingularityCore/Plugins/CommandPolicy.swift`, `Tests/SingularityCoreTests/Fixtures/plugins/` (folders below)
- Modify: `Tests/SingularityCoreTests/PluginTests.swift`, `Sources/SingularityCore/Persistence/Paths.swift` (`pluginsDirectory`, `pluginsDataDirectory(_ id:)`, `pluginStateFile`)

**Interfaces:**
- Consumes: `SitePattern`, `PluginError` (Task 2).
- Produces:
  - `public struct PluginManifest: Codable, Equatable, Sendable`, with `id, name, version, description, author: String`, `background: String?`, `page: Page?` and `permissions: Permissions`.
  - `Page { script: String; sites: [String] }`.
  - `Permissions { pageAdditions, fillForms: [String]; commands: [String: [String]]; network: [String] }`, each defaulting to empty.
  - `public static func load(from folder: URL) throws(PluginError) -> PluginManifest`.
  - `public enum CommandPolicy { public static let refused: Set<String>; public static func allows(command: String, arguments: [String], declared: [String: [String]]) -> Bool }`.
  - `PluginError` cases: `invalidJSON(String)`, `invalidID(String)`, `idDoesNotMatchFolder(id: String, folder: String)`, `missingFile(String)`, `unknownPermission(String)`, `invalidSitePattern(String)`, `refusedCommand(String)`, `networkNotAvailable`, `missingLockfile`.

- [ ] **Step 1:** Fixture folders, each with a `plugin.json`:
  - `ok-1password` (the spec's sketch, plus `background.ts` and `page.ts` stubs);
  - `bad-network` (`network: ["api.example.com"]`);
  - `bad-shell` (`commands: {"sh": []}`);
  - `bad-key` (permission `"cookies": []`);
  - `bad-id` (id `"Other"`);
  - `missing-file` (`background` points at a file that isn't there).
- [ ] **Step 2:** Tests:
  - `manifestLoadsAndValidates`: `ok-1password` loads, and `permissions.commands == ["op": ["item list", "item get"]]`.
  - `manifestRejections`: each bad fixture throws its matching case.
  - `commandPolicy`:
    - `allows("op", ["item","list","--format","json"], ["op":["item list","item get"]])` is true;
    - `("op", ["item","create"], …)` is false;
    - `("op", [], …)` is false;
    - any name in `refused` is false even when declared.
- [ ] **Step 3:** Run them. Expected: FAIL.
- [ ] **Step 4:** Implement. Decode `permissions` with a keyed container and reject unknown keys; use `refusedCommand` for names in `CommandPolicy.refused`. A sub-command is space-separated words that must equal the first arguments, word for word.
- [ ] **Step 5:** Run them. Expected: PASS.
- [ ] **Step 6:** Commit: `git commit -m "Plugins: manifest, validation and command rules"`.

### Task 4: Fingerprints, approvals, status and the sandbox profile (Core)

**Files:**
- Create: `Sources/SingularityCore/Plugins/PluginApproval.swift`, `Sources/SingularityCore/Plugins/SandboxProfile.swift`, `Sources/SingularityCore/Plugins/PermissionDescriptions.swift`
- Modify: `Tests/SingularityCoreTests/PluginTests.swift`

**Interfaces:**
- Consumes: `PluginManifest`, `PluginError`.
- Produces:
  - `public enum PluginFingerprint { public static func compute(folder: URL) throws -> String }`: SHA-256 (CryptoKit) over sorted relative paths and their contents. It skips `node_modules/`, `.git/` and `.DS_Store`, and includes `bun.lock`.
  - `public struct PluginApproval: Codable, Equatable, Sendable`, with `fingerprint: String`, `permissions: PluginManifest.Permissions`, `commandPaths: [String: String]`, `enabledSpaces: Set<UUID>`, `developmentMode: Bool` and `approvedAt: Date`.
  - `public struct PluginStateStore { public init(file: URL); public func load() -> [String: PluginApproval]; public func save(_ approvals: [String: PluginApproval]) throws }`.
  - `public enum PluginStatus: Equatable, Sendable { case new, approved, changed, permissionsWidened, invalid(PluginError) }` with `public static func evaluate(manifest: Result<PluginManifest, PluginError>, fingerprint: String, approval: PluginApproval?) -> PluginStatus`.
  - `extension PluginManifest.Permissions { public func widens(_ approved: Self) -> Bool }`.
  - `public enum SandboxProfile { public static func make(pluginFolder: URL, dataFolder: URL, runtime: URL) -> String }`.
  - `public enum PermissionDescriptions { public static func lines(for: PluginManifest.Permissions, commandPaths: [String: String]) -> [String] }`.

- [ ] **Step 1:** Tests:
  - `fingerprintChangesWithContent`: editing `page.ts` changes it; touching `node_modules/x` doesn't.
  - `statusEvaluation`, which covers:
    - no approval → `.new`;
    - same fingerprint → `.approved`.
  - `changedFilesPauseWithoutDevelopmentMode` (Review Focus 5):
    - a different fingerprint, development mode off → `.changed`;
    - development mode on → `.approved`.
  - `widenedPermissionsAlwaysAsk`: a new command, a new sub-command or a new site → `.permissionsWidened`, even in development mode. Fewer permissions isn't widening.
  - `sandboxProfile`: the text contains `(deny network*)`, `(deny process-exec*)` except the runtime path, read access for `pluginFolder` and the runtime, and read/write access for `dataFolder`. It never mentions `~/Library` or `~/Singularity/spaces`.
  - `permissionDescriptions` returns, for the 1Password manifest:
    - "Adds buttons to pages on all sites"
    - "Fills login forms on all sites"
    - "Runs /opt/homebrew/bin/op (only: item list, item get)"
    - "Never uses the internet"
- [ ] **Step 2:** Run them. Expected: FAIL.
- [ ] **Step 3:** Implement. Build the profile as SBPL text:
  - `(version 1) (deny default)`;
  - allow `process-fork`, `process-exec` of `runtime`, `file-read*` of the system libraries Bun needs (`/usr/lib`, `/System`, `/private/var/db/dyld`, `/dev/urandom`, `/dev/null`) plus `runtime` and `pluginFolder`;
  - allow `file-read* file-write*` of `dataFolder` and the temp directory;
  - allow `mach-lookup` of `com.apple.system.opendirectoryd.libinfo` only if Task 1, step 4 showed Bun needs it;
  - deny network.

  Tune it against Bun with Task 1's manual check; keep the rule list in one function with a comment per rule.
- [ ] **Step 4:** Run them. Expected: PASS.
- [ ] **Step 5:** Commit: `git commit -m "Plugins: approval fingerprints, status, sandbox profile, permission texts"`.

### Task 5: Command broker, and `op` with Touch ID (spec risk 1)

**Files:**
- Create: `Sources/SingularityCore/Plugins/CommandBroker.swift`, `Sources/Singularity/Plugins/PluginDebugCommands.swift`
- Modify: `Sources/Singularity/Palette/PaletteItem.swift` (one palette command, only in debug builds: "Plugins: Test 1Password CLI")

**Interfaces:**
- Consumes: `CommandPolicy`.
- Produces:
  - `public struct CommandResult: Codable, Equatable, Sendable { public let status: Int32; public let stdout: String; public let stderr: String; public let timedOut: Bool }`.
  - `public enum CommandBroker { public static func resolve(_ name: String, loginShell: String) -> String?; public static func run(path: String, arguments: [String], timeout: Duration) async -> CommandResult }`.

- [ ] **Step 1:** Tests:
  - `resolveFindsCommands`: `resolve("ls", loginShell: "/bin/zsh") == "/bin/ls"`; a made-up name gives `nil`.
  - `runReturnsOutput`: `run("/bin/echo", ["hi"])` gives status 0 and stdout `"hi\n"`.
  - `runTimesOutAndReportsIt` (Review Focus 2): `run("/bin/sleep", ["5"], timeout: .milliseconds(300))` gives `timedOut == true`, and the process is gone.
- [ ] **Step 2:** Run them. Expected: FAIL.
- [ ] **Step 3:** Implement:
  - `resolve` runs `loginShell -l -c 'command -v <name>'` (the same approach as terminal tabs; GUI apps don't get a shell PATH) and accepts only an absolute path to an executable file.
  - `run` uses `Process` with an empty stdin, collects both pipes, and kills the process when the timeout is reached.
- [ ] **Step 4:** Run them. Expected: PASS.
- [ ] **Step 5:** Debug palette command. It resolves `op`, runs `op item list --categories Login --format json` through `CommandBroker.run` (timeout 60 s), and shows "N logins" or the error in an alert.
- [ ] **Step 6: Manual (owner).**
  1. Turn on 1Password → Settings → Developer → "Integrate with 1Password CLI".
  2. Build with `scripts/run.sh` and run the palette command.
  3. Expected: a Touch ID prompt that names Singularity, then "N logins".
  4. If 1Password refuses an ad-hoc-signed app, repeat with `SIGN_IDENTITY=<the T748B76PPL fingerprint> scripts/run.sh`.

  Record the result in the PR. **If neither works, stop: the 1Password route needs rethinking.**
- [ ] **Step 7:** Commit: `git commit -m "Plugins: command broker; verify op + Touch ID from Singularity"`.

### Task 6: Plugin process and host bootstrap (Core)

**Files:**
- Create: `Resources/plugin-host/host.ts`, `Sources/SingularityCore/Plugins/PluginProcess.swift`, `Sources/SingularityCore/Plugins/PluginWire.swift`, `Tests/SingularityCoreTests/Fixtures/plugins/echo/` (a test plugin), `Tests/SingularityCoreTests/PluginProcessTests.swift`
- Modify: `scripts/build-app.sh`, `scripts/release.sh` (copy `Resources/plugin-host/` into `Contents/Resources/plugin-host/`)

**Interfaces:**
- Consumes: `SandboxProfile`, `CommandPolicy`, `CommandBroker`, `PluginManifest`.
- Produces:
  - `PluginWire`: Codable JSON lines, one per line.
    - App to plugin:
      - `.pageMessage(requestID: Int, tabID: UUID, frameHost: String, payload: JSONValue)`
      - `.commandResult(callID: Int, result: CommandResult)`
    - Plugin to app:
      - `.reply(requestID: Int, payload: JSONValue)`
      - `.runCommand(callID: Int, command: String, arguments: [String])`
      - `.log(level: String, message: String)`
    - Encode with a `"kind"` discriminator.
    - Define `JSONValue` as a small Codable enum (null, bool, number, string, array, object).
  - `public final class PluginProcess: @unchecked Sendable` with:
    - `init(manifest: PluginManifest, folder: URL, dataFolder: URL, runtime: URL, host: URL, commandPaths: [String: String])`
    - `start() throws`, `stop()`, `send(_ message: PluginWire)`
    - `var onReply: (@Sendable (Int, JSONValue) -> Void)?`, `var onLog: (@Sendable (String, String) -> Void)?`, `var onExit: (@Sendable (Int32) -> Void)?`

    It handles `.runCommand` itself: `CommandPolicy.allows` decides, then `CommandBroker.run` runs at the pinned path. A refusal returns a result with status 126 and stderr "not allowed by the manifest".
  - `host.ts` exposes the background API: `import { singularity } from "singularity"`, mapped by host.ts via a global. It has:
    - `singularity.onPageMessage(handler: (msg: {tabID: string; frameHost: string; payload: unknown}) => unknown | Promise<unknown>)`;
    - `singularity.run(command: string, args: string[]): Promise<{status: number; stdout: string; stderr: string; timedOut: boolean}>`;
    - `singularity.log(...values)`.
    - **No storage API in round 1:** the spec says to build only what the 1Password plugin needs, and it stores nothing.
- The `echo` fixture plugin:
  - replies `{echo: payload}`;
  - on payload `"run-op"` runs `/bin/echo` declared as command `echo` with sub-command `hello`;
  - on `"forbidden"` tries `run("echo", ["bye"])`;
  - on `"net"` tries `fetch("https://example.com")`;
  - on `"crash"` calls `process.exit(1)`.

- [ ] **Step 1:** Tests. They're skipped (`.disabled`) when `Vendor/bun/bun` is missing.
  - `roundTripsPageMessages`;
  - `runsDeclaredCommandOnly`: `hello` works and `bye` gets 126;
  - `networkIsBlocked`: the reply contains the fetch error;
  - `cannotReadOutsideItsFolder`: an attempt to read `~/Singularity/state.json` fails;
  - `restartBackoffStopsAfterThreeCrashes` (Review Focus 1): put in `PluginSupervisor`, a small type in the same file that restarts on exit at most 3 times in 60 s, then reports `.crashedRepeatedly`.
- [ ] **Step 2:** Run them. Expected: FAIL.
- [ ] **Step 3:** Implement:
  - Start `/usr/bin/sandbox-exec -p <profile> <runtime> run <host.ts> <plugin folder>/<background>`, with the working directory set to the plugin folder.
  - Exchange JSON lines over stdin and stdout; turn the plugin's stderr into `.log("error", …)`.
- [ ] **Step 4:** Run them. Expected: PASS.
- [ ] **Step 5:** Commit: `git commit -m "Plugins: sandboxed Bun process, wire protocol, supervisor"`.

### Task 7: Plugin manager, Settings → Plugins, approval sheet

**Files:**
- Create: `Sources/Singularity/Plugins/PluginManager.swift`, `Sources/Singularity/Plugins/PluginApprovalSheet.swift`, `Sources/Singularity/Settings/PluginSettings.swift`
- Modify: `Sources/Singularity/Settings/SettingsView.swift` (add the tab), `Sources/Singularity/App/AppState.swift` (`let plugins: PluginManager`)

**Interfaces:**
- Consumes: everything from Tasks 3–6, and `ArtifactWatcher` (reuse its generic `init(root:onChange:)` to watch `~/Singularity/plugins`).
- Produces: `@MainActor @Observable final class PluginManager`, with:
  - `var plugins: [InstalledPlugin]`, where `InstalledPlugin { id: String; folder: URL; manifest: Result<PluginManifest, PluginError>; status: PluginStatus; approval: PluginApproval?; logs: [String] }`, keeping the last 200 log lines;
  - `func approve(_ id: String, enabledSpaces: Set<UUID>, developmentMode: Bool) async throws`, which resolves command paths, creates `pluginsDataDirectory(id)`, installs packages (Task 9), records the fingerprint, saves state and starts the process;
  - `func setEnabled(_ id: String, space: UUID, _ on: Bool)`, `func setDevelopmentMode(_ id: String, _ on: Bool)`, `func remove(_ id: String)` (stops the plugin and moves its folder to the Trash), `func addPlugin(from folder: URL) throws` (copies it into the plugins directory);
  - `func send(pluginID: String, tabID: UUID, frameHost: String, payload: JSONValue) async -> JSONValue?`, used by Task 8.

- [ ] **Step 1:** Implement discovery: list the plugin folders, load each manifest, compute fingerprints and evaluate status. Start the `.approved` ones that are enabled in at least one Space.
- [ ] **Step 2:** Watch the folder:
  - development mode on and status still `.approved` → restart the process (and reload page scripts, Task 8);
  - otherwise re-evaluate: `.changed` or `.permissionsWidened` stops the plugin.
- [ ] **Step 3:** Settings → Plugins tab:
  - one row per plugin: name, version, author, status in plain words ("Waiting for your approval", "On", "Changed since you approved it", "Asks for more permissions", "Problem: …");
  - a Space checklist and a development-mode toggle;
  - **Review…** opens the approval sheet; **Remove…** asks for confirmation;
  - a logs disclosure;
  - **Add Plugin…** (an NSOpenPanel for a folder).
- [ ] **Step 4:** Approval sheet. It shows:
  - name, author, version, the README text;
  - `PermissionDescriptions.lines`;
  - the npm package list (Task 9);
  - the Space checklist, with the current Space ticked;
  - a "Development mode" checkbox, off by default.

  Buttons: **Approve** and **Cancel**. For an update it also lists which files changed since approval: a simple list of paths whose content hash differs.
- [ ] **Step 5: Manual.** Copy the `echo` fixture into `~/Singularity/plugins/echo`, run `scripts/run.sh` and check:
  - it shows up as waiting for approval;
  - after approval its log shows the host started;
  - an edit to its `background.ts` changes the status to "Changed since you approved it" and stops it;
  - with development mode on, the same edit restarts it.
- [ ] **Step 6:** Commit: `git commit -m "Plugins: manager, Settings → Plugins, approval sheet"`.

### Task 8: Page bridge, prelude, trusted clicks and fills

**Files:**
- Create: `Sources/Singularity/Plugins/PluginPageBridge.swift`, `Sources/Singularity/Plugins/PluginPrelude.swift` (the JS prelude as a Swift string, like `PageAgentScript`), `Sources/Singularity/Plugins/PluginScripts.swift`, `Tests/Fixtures/plugin-pages/login.html`, `Tests/Fixtures/plugin-pages/relogin.html`
- Modify: `Sources/Singularity/Web/WebViewRegistry.swift` (configurations get the plugins' scripts; rebuild on change), `Sources/SingularityCore/Plugins/` (add `FillGuard`)

**Interfaces:**
- Consumes: `PluginManager.send`, `SitePattern`, `HostMatch`.
- Produces:
  - `public enum FillGuard { public static func allows(frameHost: String, forHost: String) -> Bool }` in Core, equal to `HostMatch.isSameOrSubdomain(frameHost, of: forHost)`;
  - `public enum PluginSelection { public static func forSpace(_ spaceID: UUID, approvals: [String: PluginApproval], statuses: [String: PluginStatus]) -> [String] }` in Core: the ids of plugins that are `.approved` and enabled for that Space, sorted;
  - `PluginScripts.rebuild(_ controller: WKUserContentController, spaceID: UUID, plugins: [InstalledPlugin], agentScript: WKUserScript)`. It removes all user scripts, then re-adds the page-agent script and every plugin that is enabled for that Space. WebKit has no per-script removal.
  - The page API, defined by the prelude inside each plugin's world:
    - `singularity.send(payload): Promise<any>`;
    - `singularity.addFieldButton(input: HTMLInputElement, {title: string, iconURL?: string, onClick: (input) => void}): void`, which uses a closed shadow DOM, places the button inside the right edge of the field, uses one button per input, and calls `onClick` only when `event.isTrusted`;
    - `singularity.showMenu(anchor: Element, items: {title: string; subtitle?: string}[]): Promise<number | null>`;
    - `singularity.fillLogin({usernameInput, passwordInput, username, password}): void` (the native value setter plus input/change events, as in `PageAgentScript.type`);
    - `singularity.siteMatches: boolean` (whether the page matches the plugin's `page.sites`; the prelude doesn't run the plugin's code otherwise).

- [ ] **Step 1:** Tests in Core: `fillGuard` (exact host, subdomain, unrelated host, a lookalike) and a fixture-based `pluginScriptsForSpace` (enabled in Space A only → A gets the script and B doesn't). Keep the decision of which plugins apply to a Space in a Core function, `PluginSelection.forSpace(_:approvals:)`, so it can be tested.
- [ ] **Step 2:** Run them. Expected: FAIL.
- [ ] **Step 3:** Implement:
  - Transpile `page.ts` with `bun build <file> --no-bundle --target=browser` when the plugin loads; cache the result by fingerprint. Imports in `page.ts` are an error, shown in Settings.
  - Inject the prelude and the transpiled script into `WKContentWorld.world(name: "plugin-\(id)")` with `forMainFrameOnly: false`.
  - Register `WKScriptMessageHandlerWithReply` `"singularityPlugin"` in that world.
  - The handler takes `frameInfo.securityOrigin.host` as `frameHost` and checks it against `page.sites`, then forwards to `PluginManager.send`.
  - If the reply carries `{fill: {forHost, username, password}}`, deliver it only when `FillGuard.allows(frameHost:forHost:)`. Otherwise reply with an error, and log "blocked fill for <frameHost>" without the credentials.
- [ ] **Step 4:** Run the tests. Expected: PASS.
- [ ] **Step 5:** Fixture pages, served as artifacts in a test Space:
  - `login.html`: username and password form;
  - `relogin.html`: the form is replaced by new elements after 1 s (Review Focus 3).

  A test plugin `fixture-filler` (in `Tests/Fixtures/plugins/`) adds a button and, on click, asks its background, which replies `{fill: {forHost: "127.0.0.1", username: "u", password: "p"}}`.
- [ ] **Step 6: Manual.**
  1. On `login.html`, the button appears and a click fills `u` / `p`.
  2. On `relogin.html`, after the swap exactly one button is attached, and it fills.
  3. From the page's own console (Web Inspector), `document.querySelector(...).click()` on the button host does nothing.
  4. With the plugin enabled for Space A only and tabs open in both A and B, switching it off and on in Settings updates Space A's tabs after a reload, while Space B never shows the button (Review Focus 4).
- [ ] **Step 7:** Commit: `git commit -m "Plugins: page bridge, prelude, trusted clicks, guarded fills"`.

### Task 9: npm packages (declared and pinned)

**Files:**
- Create: `Sources/SingularityCore/Plugins/PluginPackages.swift`
- Modify: `PluginManager.approve` (install), `PluginApprovalSheet` (list), `Tests/SingularityCoreTests/PluginTests.swift`, a fixture `with-deps` with a `file:` dependency so no network is needed

**Interfaces:**
- Produces: `public struct PluginPackage: Equatable, Sendable { public let name: String; public let version: String }` and `public enum PluginPackages { public static func list(folder: URL) throws(PluginError) -> [PluginPackage] }`. That's `dependencies` from `package.json`; it throws `.missingLockfile` if there are dependencies but no `bun.lock`.

- [ ] **Step 1:** Tests: `packagesListed` (the `with-deps` fixture gives name and version); `lockfileRequired` (without `bun.lock`, `.missingLockfile`); no `package.json` gives `[]`.
- [ ] **Step 2:** Run them. Expected: FAIL. **Step 3:** Implement `list`, then call `bun install --frozen-lockfile --ignore-scripts` (bundled Bun, plugin folder as working directory, outside the sandbox) in `approve`, before the fingerprint is recorded. **Step 4:** Run them. Expected: PASS.
- [ ] **Step 5:** Commit: `git commit -m "Plugins: declared, pinned npm packages"`.

### Task 10: The 1Password plugin (success test)

**Files:**
- Create: `Plugins/1password/plugin.json` (exactly the spec's sketch, with `commands: {"op": ["item list", "item get"]}` and `network: []`), `Plugins/1password/background.ts`, `Plugins/1password/page.ts`, `Plugins/1password/README.md`, `Plugins/1password/icon.png` (a neutral key glyph; don't ship 1Password's trademarked logo)

**Interfaces:**
- Consumes: the background API (Task 6) and the page API (Task 8).
- Produces: the plugin.

- [ ] **Step 1: `background.ts`.** On `{type: "logins", frameHost}`:
  - run `op item list --categories Login --format json`;
  - keep the items with any URL whose host passes `isSameOrSubdomain(frameHost, of: itemHost)`, reimplemented in about 5 lines of TypeScript, as in Core;
  - return `{logins: [{id, title, username}]}`, or `{error: "1Password is locked or unavailable"}` on a non-zero status or timeout (Review Focus 2).

  On `{type: "fill", id, frameHost}`:
  - run `op item get <id> --fields username,password --reveal --format json`;
  - return `{fill: {forHost: <the item's matching host>, username, password}}`.
- [ ] **Step 2: `page.ts`.** Find login forms: a visible `input[type=password]`, plus the nearest preceding visible text, email or `autocomplete=username` input. Add the field button to both. Watch with a `MutationObserver`, at most one button per input.

  On click:
  - `send({type: "logins"})`;
  - 0 logins → `showMenu` with the disabled item "No logins for this site";
  - 1 login → fill straight away;
  - more → `showMenu` with title and username;
  - then `send({type: "fill", id})` and `fillLogin`.
- [ ] **Step 3:** Copy it to `~/Singularity/plugins/1password` with **Add Plugin…** and approve it. The sheet shows "Runs /opt/homebrew/bin/op (only: item list, item get)" and "Never uses the internet".
- [ ] **Step 4: Manual success test (owner).**
  1. github.com/login in a Space where the plugin is enabled: the button appears in both fields.
  2. A click shows Touch ID, then fills, or shows a menu when there are several GitHub logins.
  3. With 1Password locked and Touch ID cancelled, "1Password is locked or unavailable" appears within 60 s.
  4. The Space where it's not enabled shows no button.
- [ ] **Step 5:** Commit: `git commit -m "Plugins: 1Password plugin (fill logins via op + Touch ID)"`.

### Task 11: Authoring guide, template, docs

**Files:**
- Create: `docs/plugins/AUTHORING.md`, `Plugins/template/` (`plugin.json`, `background.ts`, `page.ts`, `README.md`)
- Modify: `CLAUDE.md` (scope change: "browser extensions" and "AI chat" are replaced by "Singularity plugins, AI only inside plugins", plus the architecture of `Plugins/`), `README.md` (a Plugins section), `IDEAS.md` (web-extension compatibility parked, with the spike results)

- [ ] **Step 1:** `AUTHORING.md`, written for agents and people. It covers:
  - the folder layout;
  - the manifest, with each permission, what it allows and what it shows at install;
  - the background and page APIs, with exact signatures from Tasks 6 and 8;
  - the rules: no imports in `page.ts`, no network in round 1, no minified or generated code, npm only with `bun.lock`;
  - how to test with development mode;
  - a review checklist for people.
- [ ] **Step 2:** Make `Plugins/template/` a working minimal plugin: a page button that logs a message to its background.
- [ ] **Step 3:** Ask an agent in a Singularity terminal tab: "Using docs/plugins/AUTHORING.md, write a plugin that adds a button to password fields showing the field's length." Expected: it appears for approval and works. Note any confusion in the guide and fix it.
- [ ] **Step 4:** Commit: `git commit -m "Plugins: authoring guide, template, docs"`.
