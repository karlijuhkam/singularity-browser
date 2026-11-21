# Browser extensions, Chrome compatibility: implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Chrome extensions that WebKit can't run as they are (1Password's above all) run from an adapted copy that Singularity builds from the approved original.

**Architecture:** A pure Core adapter (`CompatAdapter`) copies an extension folder and changes the copy: rewrites real uses of missing `chrome.*` members, adds a stand-ins file (`sg-compat.js`), turns a WebSocket-using service worker into a background page, applies a per-id recipe. `ExtensionCenter` runs it at install, at launch (when the adapter version or the copy's fingerprint changed) and on automatic updates, and loads the adapted folder instead of the original.

**Tech Stack:** Swift 6 / SwiftPM, Swift Testing, WebKit `WKWebExtension` (macOS 15.4+), JavaScriptCore in one Core test.

**Spec:** `docs/superpowers/specs/2026-11-21-extension-compat-design.md`

## Global Constraints

- Originals stay byte for byte in `~/Singularity/extensions/<id>/` with their approved `fingerprint`; adapted copies go to `~/Singularity/extensions-adapted/<id>/`.
- Record fields (tolerant decoding, absent when unused): `adaptation` (Int, `CompatAdapter.version`), `adaptedFingerprint` (String, `PluginFingerprint` of the adapted folder), `adaptationSummary`.
- `CompatAdapter.version = 1`; bump whenever the adapter's output changes.
- The adapted manifest asks for exactly the original's permissions and match patterns (checked in Core and again in the app against `WKWebExtension`).
- No logging per message, no page content, no form values; `sg-compat.js` logs nothing.
- 1Password id `aeblfdkhhhdcdjpifhhbdiojplfjncoa`; its recipe must match 8.12.46.29 (the store still serves it on 2026-11-21). 1Password's files are never committed.
- Tests: no network (except opt-in), no key window, `TestAppState.make(root:)` / `shutDown`, nested in `AppTests`.
- Always load extensions from absolute, standardised file URLs.

## Builder's calls made in this plan

- **Rewrite form:** a use becomes `globalThis[globalThis.__sg?"__sg":"chrome"].<ns>.<member>` (`"browser"` when written `browser`), not the spec's `(globalThis.__sg ?? chrome)`: a replacement that starts with `(` can join the previous line through ASI (`foo\n(…)` is a call). Same behaviour, identifier-led. `?.` between namespace and member is matched too.
- **Whole missing namespaces** (`idle`, `management`, `privacy`, `downloads`, `notifications`): a real use triggers the stand-ins file but no rewrite (assignment onto `chrome` works).
- **`adaptation` is also written when nothing was needed** (with `adaptedFingerprint` nil): "checked with adapter N, needs nothing", so launch doesn't re-scan every extension each time.
- **Stand-ins in a worker that stays a worker:** a generated entry next to the worker (`sg-worker.js`: `import` for a module worker, `importScripts` for a classic one) loads `sg-compat.js` first, then the original.
- **Background page:** `sg-background.html` in the worker file's folder (relative URLs keep their base); classic workers: the literal string arguments of `importScripts(...)` become `<script>` tags before the worker file, and the page defines a no-op `importScripts`.
- **MAIN-world content scripts** don't get `sg-compat.js` (their `chrome` is the page's).
- **HTML pages:** every `.html`/`.htm` file gets `<script src="/sg-compat.js"></script>` right after `<head…>` (or after `<html…>`, or at the start).
- **Test seam:** `ExtensionCenter.adapter` (a closure, default `CompatAdapter.adapt`) so app tests can make adapting fail.

## Review Focus

1. Code shapes around a rewritten use: a use at the start of a line after a statement without `;`, `chrome.action?.getUserSettings`, `typeof chrome.runtime.onSuspend`, a longer identifier (`chrome.runtime.onSuspendX`, `mychrome.runtime.onSuspend`, `x.chrome.runtime.onSuspend`): must stay valid JS with the same meaning. Test in Task 1.
2. Listed members inside strings, template text, comments and regex literals (`/chrome\.storage\.managed/`) are not "real uses": an extension that only names one is not adapted. Test in Task 1.
3. An extension that ran unadapted before and needs adapting with the current adapter (uBlock Origin Lite reading `storage.managed`) is adapted at launch without a sheet and keeps its Spaces. Test in Task 5.
4. An adapted copy changed on disk is never loaded: it is rebuilt from the original. Test in Task 5.
5. An adapter failure (at launch or on an automatic update) keeps the old version running and says so; with no usable copy the extension is paused. Test in Task 5.

---

### Task 1: JavaScript source analysis (Core)

**Files:**
- Create: `Sources/SingularityCore/Extensions/CompatSource.swift`
- Test: `Tests/SingularityCoreTests/ExtensionCompatTests.swift`

**Interfaces:**
- Produces:
  - `public enum CompatMembers { public static let missing: [(ns: String, member: String)]; public static let missingNamespaces: [String] }` with exactly the spec's list: `webNavigation.onCreatedNavigationTarget/onHistoryStateUpdated/onReferenceFragmentUpdated/onTabReplaced`, `webRequest.onAuthRequired/onBeforeRedirect/onSendHeaders/onResponseStarted`, `runtime.requestUpdateCheck/onSuspend/onMessageExternal/onConnectExternal/onUpdateAvailable/onRestartRequired`, `permissions.addHostAccessRequest/removeHostAccessRequest`, `action.getUserSettings`, `storage.managed`, `windows.onFocusChanged/onCreated`; namespaces `idle, management, privacy, downloads, notifications`.
  - `public enum CompatSource`:
    - `static func codeMask(_ utf8: [UInt8]) -> [Bool]` (true = byte is code: outside strings, template text (but `${…}` is code), comments, regex literals).
    - `static func rewrite(_ text: String) -> (text: String, members: Set<String>)` (members as `"ns.member"`).
    - `static func usedNamespaces(_ text: String) -> Set<String>` (real uses of `missingNamespaces`).
    - `static func constructsWebSocket(_ text: String) -> Bool` (code `new WebSocket(` / `new WebSocket` followed by `(` after whitespace; also `new globalThis.WebSocket(` and `new self.WebSocket(`).
    - `static func staticImports(_ text: String) -> [String]` (relative specifiers of `import … from "x"`, `import "x"`, `export … from "x"` in code, in order).
    - `static func importScriptsArguments(_ text: String) -> [String]` (string-literal args of `importScripts(...)` in code).

- [ ] **Step 1: Write the failing tests** in `ExtensionCompatTests.swift` (`@Suite struct CompatSourceTests`):
  - `rewritesEachListedMember`: for every entry of `CompatMembers.missing`, `rewrite("chrome.\(ns).\(m).addListener(f)")` → text `globalThis[globalThis.__sg?"__sg":"chrome"].\(ns).\(m).addListener(f)`, members `["\(ns).\(m)"]`; same with `browser.` → `"browser"`.
  - `rewritesOptionalChaining`: `chrome.action?.getUserSettings!==void 0` → `globalThis[globalThis.__sg?"__sg":"chrome"].action?.getUserSettings!==void 0`.
  - `leavesLongerNamesAlone`: `chrome.runtime.onSuspendX`, `mychrome.runtime.onSuspend`, `x.chrome.runtime.onSuspend`, `chrome.runtime.onMessage`, `chrome.storage.local` → unchanged, members empty.
  - `asiSafe`: `"foo()\nchrome.runtime.onSuspend.addListener(f)"` rewritten text, evaluated in a `JSContext` with `chrome = {runtime:{onSuspend:{addListener(f){globalThis.ok=1}}}}` and `foo = () => 0`, sets `ok` to 1 (no "is not a function").
  - `skipsNonCode`: `'chrome.storage.managed'`, `"chrome.storage.managed"`, `` `chrome.storage.managed ${x}` ``, `// chrome.storage.managed`, `/* chrome.storage.managed */`, `/chrome\.storage\.managed/.test(s)`, `a = b / chrome.x / c` (division, not regex: here `chrome.x` isn't listed; assert mask marks `chrome` as code) → no members; but `` `${chrome.storage.managed}` `` → rewritten.
  - `webSocketDetection`: true for `new WebSocket(u)`, `new WebSocket (u)`, `x=new self.WebSocket(u)`; false for `"new WebSocket(u)"`, `// new WebSocket(u)`, `typeof WebSocket`, `WebSocket.OPEN`.
  - `importsAndImportScripts`: `import a from "./a.js";import "../b.js";export {c} from './c.js';import("./lazy.js")` → `["./a.js","../b.js","./c.js"]` (dynamic import not followed); `importScripts("x.js", 'y.js')` → `["x.js","y.js"]`.
  - `namespaces`: `chrome.idle.queryState(60)` → `["idle"]`; `"chrome.idle"` → `[]`.

- [ ] **Step 2: Run to see them fail.** `source scripts/env.sh && swift test --filter CompatSourceTests` → compile error (no `CompatSource`).

- [ ] **Step 3: Implement `CompatSource`.** Byte scanner over UTF-8 with states code / `'` / `"` / template (with a brace-depth stack for `${}`) / line comment / block comment / regex (with `[...]` class). A `/` starts a regex when the previous significant code token is not an identifier/number/`)`/`]`/`}` — except after the keywords `return typeof instanceof in of new delete void throw case do else yield await`. Matching: at a code byte where `chrome`/`browser` starts and the previous byte is not an identifier char, `$`, or `.`, read `\s*(\?\.|\.)\s*ns\s*(\?\.|\.)\s*member` and require the next byte not be an identifier char; replace only the `chrome`/`browser` word. Build the output by splicing byte ranges.

- [ ] **Step 4: Run the tests.** `swift test --filter CompatSourceTests` → PASS.

- [ ] **Step 5: Commit** `Extensions compat: JavaScript source analysis`.

### Task 2: Stand-ins, recipes and the adapter (Core)

**Files:**
- Create: `Sources/SingularityCore/Extensions/CompatStandIns.swift`, `Sources/SingularityCore/Extensions/CompatRecipe.swift`, `Sources/SingularityCore/Extensions/CompatAdapter.swift`
- Test: `Tests/SingularityCoreTests/ExtensionCompatTests.swift`

**Interfaces:**
- Consumes: Task 1's `CompatSource`, `CompatMembers`; `PluginFingerprint.listFiles(folder:)`.
- Produces:
  - `public enum CompatStandIns { public static let fileName = "sg-compat.js"; public static let script: String }`
  - `public struct CompatRecipe: Sendable { public let id: String; public let name: String; public let backgroundAsPage: Bool; public let replacements: [Replacement]; public struct Replacement: Sendable { public let file: String; public let pattern: String; public let guardPattern: String?; public let template: String; public let count: Int }; public static let all: [String: CompatRecipe]; public static let onePassword: CompatRecipe }`
  - `public struct CompatSummary: Codable, Equatable, Sendable { public var standIns: [String]; public var backgroundPage: Bool; public var recipe: String?; public var text: String }`
  - `public enum CompatAdapter { public static let version = 1; public static func adapt(original: URL, into: URL, extensionID: String) throws -> CompatSummary?; public enum Failure: Error, LocalizedError, Equatable { case unreadableManifest, recipeMismatch(String, expected: Int, found: Int), permissionsChanged, unreadableFile(String) } }`

- [ ] **Step 1: Write the failing tests** (`@Suite struct CompatAdapterTests`, each in a `mktemp`-style folder under `FileManager.default.temporaryDirectory/sg-compat-<8 hex>`):
  - `needsNothing`: a manifest + `bg.js` using only `chrome.runtime.onMessage` → returns nil, `into` not created.
  - `memberUseAddsStandIns`: content script `cs.js` uses `chrome.storage.managed.get`, MAIN-world script `main.js`, page `popup.html` with `<head><title>x</title>`, module worker `bg.js` using `chrome.runtime.onSuspend` → summary `standIns == ["runtime.onSuspend","storage.managed"]`, `backgroundPage == false`; adapted `content_scripts[0].js == ["sg-compat.js","cs.js"]`, MAIN entry unchanged; `popup.html` contains `<head><script src="/sg-compat.js"></script><title>`; `background.service_worker == "sg-worker.js"`, `type` kept `module`, `sg-worker.js` == `import "./sg-compat.js";\nimport "./bg.js";\n`; `sg-compat.js` == `CompatStandIns.script`; `cs.js` rewritten.
  - `classicWorkerEntry`: classic worker in `js/bg.js` using `chrome.idle` → `sg-worker.js` at top is `importScripts("/sg-compat.js", "/js/bg.js");\n`.
  - `webSocketMakesAPage` (module): worker `bg.js` imports `./net.js` which does `new WebSocket(u)` → `background == {"page":"sg-background.html","persistent":false}`; page = `<!doctype html><meta charset="utf-8"><script src="/sg-compat.js"></script><script type="module" src="bg.js"></script>`; `backgroundPage == true`.
  - `webSocketClassic`: classic worker with `importScripts("a.js")` and `new WebSocket` in `a.js` → page lists `/sg-compat.js`, a no-op `importScripts` shim script (`sg-import-scripts.js`), `a.js`, then the worker, in that order.
  - `mentionIsNotAUse`: `bg.js` with `// new WebSocket(` and `"chrome.storage.managed"` → nil.
  - `dropsUpdateURLAndMetadata`: manifest with `update_url` and a `_metadata/verified_contents.json` plus a member use → adapted manifest has no `update_url`, no `_metadata` folder.
  - `deterministic`: adapting the same folder twice into two folders gives the same `PluginFingerprint.compute`.
  - `recipeApplies`: a fixture under id `aeblfdkhhhdcdjpifhhbdiojplfjncoa` whose `background/background.js` (module) holds `function E_e(A){return browser.runtime.getManifest().manifest_version===A}function Xl(){return E_e(3)}function Jl(){return Xl()&&Fs()}var Fs=()=>!0;` → contains `function Jl(){return Xl()&&Fs()&&typeof ServiceWorkerGlobalScope!=="undefined"}`, background is a page in `background/`, summary `recipe == "1Password"`, text `"Singularity adapts this extension to run here: background as a page, 1Password recipe."`.
  - `recipeWrongCountFails`: same fixture with the function twice → throws `.recipeMismatch(_, expected: 1, found: 2)`; with zero → `found: 0`; `into` not left behind.
  - `summaryText`: `CompatSummary` for 3 stand-ins + page → `"Singularity adapts this extension to run here: stand-ins for 3 Chrome features, background as a page."`; 1 stand-in → `"stand-ins for 1 Chrome feature"`.
  - `standInsBehave` (JavaScriptCore): with a fake `chrome` (`runtime: {id:"x", getManifest(){return {name:"N",version:"1"}}, onMessage:{}}, storage: {local:{get(){return Promise.resolve({a:1})}}}`) evaluate `CompatStandIns.script`, then check: `chrome.idle` exists and `chrome.idle.queryState(60)` resolves `"active"`; `__sg.storage.managed.get()` resolves `{}`; `__sg.storage.local.get()` resolves `{a:1}` (the real one wins); `__sg.runtime.requestUpdateCheck(cb)` calls `cb({status:"no_update"})`; `__sg.action.getUserSettings()` resolves `{isOnToolbar:true}`; `chrome.downloads.download({})` rejects; `chrome.management.getSelf()` resolves `name == "N"`; `chrome.management.setEnabled("x", false)` rejects; `__sg.webNavigation.onTabReplaced.hasListener(f)` false after `addListener(f); removeListener(f)`; loading the script twice is harmless. Script text contains neither `console.` nor `sendNativeMessage`.

- [ ] **Step 2: Run to see them fail.** `swift test --filter CompatAdapterTests` → compile error.

- [ ] **Step 3: Implement.**
  - `CompatStandIns.script`: an IIFE guarded by `if (globalThis.__sg) return;` and `const real = globalThis.chrome || globalThis.browser; if (!real || !real.runtime) return;`. Events: `{addListener, removeListener, hasListener, hasListeners}` that never fire. `api(fn)`: last-arg callback or Promise. Behaviours as listed in the spec's step 2 (`privacy.services.<setting>.get` → `{value:false, levelOfControl:"not_controllable"}`, `set`/`clear` reject; `notifications.create` resolves an id; `downloads.download` rejects `"Downloads from extensions aren't available in Singularity."`; `management.getAll` → `[getSelf()]`). Missing namespaces are assigned onto `real` only when `real[ns] === undefined`. `globalThis.__sg = new Proxy({}, {get: (_, ns) => merge(real[ns], extras[ns])})`, where `merge` returns the real value for any key the real object has (functions bound), else the stand-in, recursing for `storage.managed`.
  - `CompatRecipe.onePassword`: `backgroundAsPage: true`, one replacement in `background/background.js`: pattern `function ([\w$]+)\(\)\{return ([\w$]+)\(\)&&([\w$]+)\(\)\}`, guard `function $2\(\)\{return [\w$]+\(3\)\}` (with `$2` regex-escaped; a match whose guard finds nothing in the same file doesn't count), count 1, template `function $1(){return $2()&&$3()&&typeof ServiceWorkerGlobalScope!=="undefined"}`. The guard is what makes it "the manifest-version-3 check and only it".
  - `CompatAdapter.adapt`: read `manifest.json` (JSONSerialization; fail `.unreadableManifest`). Analyse every `.js` (excluding `_metadata/`): members via `rewrite`, namespaces via `usedNamespaces`. Find the worker (`background.service_worker`, `type`), its import closure (module: `staticImports`, relative only, resolved within the folder; classic: `importScriptsArguments`), WebSocket in any of them. Recipe = `CompatRecipe.all[extensionID]`. If no member, no namespace, no WebSocket and no recipe → return nil. Else: copy every file (sorted, `PluginFingerprint.listFiles`) except `_metadata/` into `into`; write rewritten `.js`; insert into `.html`/`.htm`; write `sg-compat.js`; update `content_scripts` (skip `world == "MAIN"`); background: page when WebSocket or `recipe.backgroundAsPage`, else `sg-worker.js`; apply recipe replacements with exact counts (`.recipeMismatch(file, expected:, found:)`); drop `update_url`; write the manifest with `[.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]`. Check: original and adapted manifests, each without `update_url`, `background` and every `content_scripts[i].js`, are equal as `NSDictionary` (else `.permissionsChanged`). On any throw remove `into`. A file that isn't UTF-8 is copied unchanged and not analysed.

- [ ] **Step 4: Run the tests.** `swift test --filter "CompatAdapterTests|CompatSourceTests"` → PASS.

- [ ] **Step 5: Commit** `Extensions compat: stand-ins, recipes and the adapter`.

### Task 3: Record fields, launch rules, paths (Core)

**Files:**
- Modify: `Sources/SingularityCore/Extensions/ExtensionRecord.swift`, `Sources/SingularityCore/Persistence/Paths.swift`
- Test: `Tests/SingularityCoreTests/ExtensionCoreTests.swift`

**Interfaces:**
- Produces:
  - `ExtensionRecord.adaptation: Int?`, `.adaptedFingerprint: String?`, `.adaptationSummary: CompatSummary?` (init params default nil; encoded only when non-nil).
  - `ExtensionRules.Status` gains `.cannotAdapt` (paused: no usable adapted copy).
  - `public enum AdaptationStep: Equatable { case original, adapted, rebuild }` and `ExtensionRules.adaptationStep(_ record: ExtensionRecord, adaptedFingerprintNow: String?, adapterVersion: Int = CompatAdapter.version) -> AdaptationStep`.
  - `ExtensionRules.afterFailedRebuild(_ record: ExtensionRecord, adaptedFingerprintNow: String?) -> AdaptationStep?` (`.adapted` when the old copy still matches, else nil = paused).
  - `Paths.extensionsAdaptedDirectory` (`<root>/extensions-adapted/`), in the layout comment.

- [ ] **Step 1: Failing tests** in `ExtensionRecordTests`: `adaptationFieldsRoundTrip` (with and without the three fields; a file without them decodes nil; a broken `adaptationSummary` decodes nil, record kept); `adaptationSteps`: version nil → `.rebuild`; version 0 (old) → `.rebuild`; current + fingerprint nil → `.original`; current + matching → `.adapted`; current + other/nil now → `.rebuild`; `afterFailedRebuild`: matching old copy → `.adapted`, missing → nil.
- [ ] **Step 2: Run** `swift test --filter ExtensionRecordTests` → fails to compile.
- [ ] **Step 3: Implement** the fields, the rules and `Paths.extensionsAdaptedDirectory`.
- [ ] **Step 4: Run** → PASS; also `swift test --filter "Extension"` (Core) → PASS.
- [ ] **Step 5: Commit** `Extensions compat: record fields and launch rules`.

### Task 4: The app uses the adapter

**Files:**
- Modify: `Sources/Singularity/Extensions/ExtensionCenter.swift`, `Sources/Singularity/Extensions/ExtensionViews.swift`, `Sources/Singularity/Settings/ExtensionSettings.swift`

**Interfaces:**
- Consumes: Tasks 2–3.
- Produces:
  - `ExtensionCenter.adapter: @Sendable (URL, URL, String) throws -> CompatSummary?` (default `CompatAdapter.adapt`).
  - `ExtensionCenter.adaptedFolder(of:) -> URL`, `loadFolder(of:) -> URL` (adapted when the record has `adaptedFingerprint` and the step at start was `.adapted`).
  - `ExtensionCenter.adaptNotes: [String: String]` (Settings shows them in orange).
  - `PendingExtension.adaptation: PendingAdaptation` where `enum PendingAdaptation { case none, adapted(folder: URL, summary: CompatSummary), failed(String) }`; `webExtension` is the adapted one when adapted.
  - `ExtensionCenter.installUpdate(_ staged: ExtensionInstaller.Staged, current: ExtensionRecord) async` (what `checkStoreUpdates` does after the download; tests call it).

- [ ] **Step 1: Start.** In `start()`, after statuses: for each `.ready` record, off the main thread fingerprint `adaptedFolder(of:)` when it exists, take `adaptationStep`; `.rebuild` → run `adapter(original, stageDir/x, id)`; success with a summary → swap into `extensions-adapted/<id>` (old moved aside into the stage, then removed), record `adaptation`, `adaptedFingerprint`, `adaptationSummary`; nil → record `adaptation = version`, clear the other two, remove any old adapted folder; failure → `afterFailedRebuild`: `.adapted` with note "Couldn't be adapted by this version of Singularity; the previous adaptation is running." or `statuses[id] = .cannotAdapt` with note "Couldn't be adapted by this version of Singularity." Save once. Then load as today from `loadFolder(of:)`.
- [ ] **Step 2: Install.** `present` and `installUpdate` run the adapter on `staged.root` into `staged.stage/adapted`; `.adapted` → `WKWebExtension(resourceBaseURL:)` of the adapted folder, and fail (`.failed("…asks for different permissions…")`) unless its `requestedPermissions`/`allRequestedMatchPatterns` equal the original's. `approve` moves the adapted folder to `extensions-adapted/<id>` (replacing any old one) with the original, fingerprints both, and writes the three fields (or `adaptation = version` and nil when `.none`). `remove` also removes the adapted folder. Approve refuses `.failed` (guard).
- [ ] **Step 3: Updates.** `checkStoreUpdates` calls `installUpdate`; adapter failure → stage removed, `adaptNotes[id] = "Version X couldn't be adapted; version Y is running."`, no sheet, old one untouched; success clears that note.
- [ ] **Step 4: Sheet.** Under the permissions: `.adapted` → the summary's `text` (secondary); `.failed` → "Singularity can't adapt this extension to run here, so it can't be installed." plus the reason in caption, and Install/Update disabled.
- [ ] **Step 5: Settings.** Under a row's status: "Adapted: " + summary text without its lead-in (store a short form: `CompatSummary.short`, e.g. "stand-ins for 3 Chrome features, background as a page, 1Password recipe"); `adaptNotes[id]` in orange; `.cannotAdapt` → "Paused: couldn't be adapted by this version of Singularity." Change the intro line to "Extensions work as in Safari. Chrome extensions that need Chrome-only features are adapted to run here where Singularity can (1Password's is). Each Space runs its own copy."
- [ ] **Step 6: Build.** `source scripts/env.sh && swift build` → no errors; `swift test --filter ExtensionTests` (existing tests) → PASS.
- [ ] **Step 7: Commit** `Extensions compat: install, launch and updates use adapted copies`.

### Task 5: App tests

**Files:**
- Modify: `Tests/SingularityAppTests/ExtensionTests.swift`

- [ ] **Step 1: Fixture.** `Site` grows a WebSocket endpoint `/ws` (handshake with `Sec-WebSocket-Accept`, then holds the socket open). Second fixture extension `local-0f0f0f0f` ("SG WS Fixture"): module worker `bg.js` that imports `./net.js`, where `net.js` opens `new WebSocket("ws://127.0.0.1:<port>/ws")` and records `open`; `bg.js` answers `{ws: state, managed: typeof (await chrome.storage.managed.get())}` to a content script ping (using a listed member). `Rig` gets a `fixture` parameter.
- [ ] **Step 2: Tests.**
  - `webSocketExtensionIsAdaptedAndConnects`: record written without adaptation → after start, `extensions-adapted/local-0f0f0f0f/sg-background.html` exists, record has `adaptation == CompatAdapter.version` and a summary with `backgroundPage`, and the page's content script reads back `ws == "open"` and `managed == "object"`.
  - `plainExtensionLoadsFromOriginal`: the existing fixture → `adaptation == version`, `adaptedFingerprint == nil`, no `extensions-adapted/local-0e0e0e0e`, content script still answers (existing assertion).
  - `changedAdaptedCopyIsRebuilt`: after the first test's start, shut down, overwrite `extensions-adapted/…/bg.js` with `/* evil */`, start a new `AppState` on the same root → the file is back to the adapted content, fingerprint equals the recorded one, extension runs.
  - `failedRebuildKeepsTheOldCopy`: adapted copy in place, record with `adaptation = 0`, `center.adapter` throwing → note "previous adaptation is running", extension runs. Without the old copy → `.cannotAdapt`, not loaded.
  - `failedUpdateKeepsTheOldVersion`: `installUpdate` with a staged v2 and a throwing adapter → record version still 1.0, note "Version 2.0 couldn't be adapted; version 1.0 is running.", stage removed.
  - `realOnePasswordAdapts` (opt-in `SG_REAL_CRX=<path>:aeblfdkhhhdcdjpifhhbdiojplfjncoa`): stage the `.crx` with `ExtensionInstaller.stage(crx:id:installDirectory:)` into a temp root, adapt → summary `recipe == "1Password"`, `backgroundPage`; `WKWebExtension` of the adapted folder has the same permissions and patterns as the original and no errors beyond the original's.
- [ ] **Step 3: Run** `source scripts/env.sh && swift test --filter ExtensionTests` → PASS; and with `SG_REAL_CRX=<scratch op.crx>:aeblfdkhhhdcdjpifhhbdiojplfjncoa` → PASS.
- [ ] **Step 4: Commit** `Extensions compat: app tests`.

### Task 6: Docs, full gate, merge, release

**Files:**
- Modify: `CLAUDE.md`, `IDEAS.md`, `docs/superpowers/specs/2026-11-21-extension-compat-design.md` ("As built" section)

- [ ] **Step 1: Docs.** CLAUDE.md: the scope line ("Still out: shims for Chrome-only APIs" → adapted per the compat spec, still out: native messaging…), the Core/App layout lines (`CompatSource`, `CompatStandIns`, `CompatRecipe`, `CompatAdapter`; `extensions-adapted/`), and a "Chrome compatibility" bullet of things to keep (the constraints, adapted folder + fingerprint + rebuild, recipes as data with exact counts, the rewrite form, no logging, one sign-in per Space). IDEAS.md: drop shims from "Extensions, round 2", keep 1Password desktop-app unlock as needing 1Password. Spec: "As built" with the builder's calls above.
- [ ] **Step 2: Full gate.** `scripts/test.sh` → all pass (session unlocked; see the test-gate memory).
- [ ] **Step 3: Review.** A fresh reviewer on the whole branch diff; fix what holds up.
- [ ] **Step 4: Merge.** `git fetch`, `git worktree list`; rebase on `origin/main` if it moved; merge into `main` in the worktree that has it (fast-forward), push.
- [ ] **Step 5: Release.** `scripts/release.sh 0.20.0 --yes` from the `main` worktree (owner asked for a new version); confirm the GitHub release and `appcast.xml`.
- [ ] **Step 6: Memory.** Update the 1Password spike memory and add an owner-checks note for 0.20.0.
