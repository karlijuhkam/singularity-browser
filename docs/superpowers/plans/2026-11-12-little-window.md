# Little Windows Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A link clicked in another app opens in its own throwaway Singularity window; one action moves it into a Space.

**Architecture:** A little window's page is an ordinary `WebTabController` in `WebViewRegistry`, under a tab id no Space has, with `isLittle = true`. `LittleWindows` (on `AppState`) owns the AppKit windows; moving into the home Space adds a `BrowserTab` with the same id and hands the live web view to the pane. Only release bundles declare the http/https schemes.

**Tech Stack:** Swift, AppKit (`NSWindow`, title-bar accessory), SwiftUI for the chrome, WebKit. No new dependency.

**Spec:** `docs/superpowers/specs/2026-11-12-little-window-design.md`

## Global Constraints

- No new dependency. Bundle id stays `dev.roosa.Singularity`.
- Only `scripts/release.sh` in `release` mode stamps `CFBundleURLTypes` (http, https). `build-app.sh`, `--skip-notarize` and `--scratch` bundles never claim links.
- Never call the real "make default" in tests; never send a link through macOS (`open https://…`) in a test or trial.
- App tests keep windows off screen and never activate the app.
- Boring, commented Swift.

## Review Focus

1. A link that is a download (no page ever commits): the empty little window closes itself; with a page already showing it stays.
2. The main window was closed, then "Open in …": the main window is opened first, the app does not quit.
3. The home Space is deleted while its little window is open: window closed, controller gone before the data store is removed.
4. A link arriving before `AppState` is attached to the delegate (cold launch): queued, opened once.
5. Title/address changes of a little page must not mark the Space dirty (no `space.json` rewrite), and no favicon file is written.

---

### Task 1: Core rules

**Files:** Create `Sources/SingularityCore/Web/LittleWindow.swift`, `Sources/SingularityCore/Web/DefaultBrowser.swift`; Test `Tests/SingularityCoreTests/LittleWindowTests.swift`.

**Produces:**
- `enum LittleWindowRules`: `static func accepts(_ url: URL) -> Bool` (http/https with a host); `static func addressText(_ url: URL?) -> String` (host without `www.` + path, no scheme/query; "" for nil); `static func homeSpace(selected: UUID?, spaces: [UUID]) -> UUID?`; `enum OpenAction { case move, reload(URL) }`; `static func openAction(home: UUID, chosen: UUID, current: URL?, failed: URL?, first: URL) -> OpenAction` (same Space → `.move`; else `.reload(failed ?? current ?? first)`).
- `enum DefaultBrowserStatus { case isDefault, otherCopyIsDefault(path: String), notDefault, unavailable(String) }` and `enum DefaultBrowserRules`: `static func claimsLinks(infoPlist: [String: Any]) -> Bool`; `static func status(infoPlist:, bundlePath:, bundleID:, defaultAppPath: String?, defaultAppBundleID: String?) -> DefaultBrowserStatus`; `text` per status.

- [ ] Tests first (each rule above, with the spec's cases), run, implement, run, commit.

### Task 2: The little flag, registry, `LittleWindows` without chrome

**Files:** Modify `Web/WebTabController.swift`, `Web/WebViewRegistry.swift`, `App/AppState.swift`, `Sites/PageCaptureScript.swift`, `Agent/AgentApprovals.swift`, `App/MainView.swift`, `App/SingularityApp.swift`; Create `Sources/Singularity/LittleWindow/LittleWindows.swift`; Test `Tests/SingularityAppTests/LittleWindowTests.swift`.

**Produces:**
- `WebTabController.isLittle: Bool` (var, default false), `onLittleClose: (() -> Void)?`, `hasCommittedPage: Bool`, `failedURL` readable, `pageTitle`/`pageURL` observed properties.
  While little: no `webTabDidChange`, no `recordVisit`, no favicon; `createWebViewWith` loads in place and returns nil; `webViewDidClose` and "download started with no page" call `onLittleClose`.
- `WebViewRegistry.littleController(id:url:in:) -> WebTabController`; `littleControllers(in spaceID:)`.
- `LittleWindows` (`@MainActor @Observable`): `open(_ url: URL) -> LittleWindow?`, `windows: [LittleWindow]`, `keyWindow: LittleWindow?`, `close(_:)`, `openInSpace(_:)`, `closeAll(in spaceID:)`. `LittleWindow`: `id`, `homeSpaceID`, `chosenSpaceID`, `controller`, `window: NSWindow`.
- `AppState.little`, `AppState.openLink(_ url: URL)`, `AppState.mainWindow` (weak, set by a window accessor in `MainView`) and `AppState.showMainWindow()` (uses a stored `openWindow` closure when the window is gone).
- `deleteSpace` calls `little.closeAll(in:)` before removing controllers; `CaptureBridge` ignores little controllers; `AgentApprovals.presentingWindow` prefers `state.mainWindow`.

- [ ] Tests first: the spec's app tests (no tab / no history / no favicon / space not dirty; two links two windows; move keeps the same `WKWebView`, records history; other Space reloads; close; `_blank`; delete Space; download link). Then implement, run, commit.

### Task 3: Window chrome and menu routing

**Files:** Create `LittleWindow/LittleWindowChrome.swift`; Modify `App/Commands.swift`, `App/AppState.swift`.

- Title-bar accessory (trailing): Space menu pill + "Open in <name>" button (⌘O via the menu command, not a hidden button); centred read-only address as the title-bar's leading/centre accessory; `LoadingBar` and `FindBar` over the page.
- `Commands`: page commands go to `state.frontController` (little window's when one is key); ⌘W → `state.closeTabCommand()` closes the key little window; "Open in Space" ⌘O item enabled only then; tab/split/sidebar/Open Location disabled then.
- [ ] Tests: ⌘W routing; chrome renders (bitmap snapshot of the window is non-empty and the button title follows the chosen Space). Commit.

### Task 4: Receiving links

**Files:** Modify `App/SingularityApp.swift`.

- `AppDelegate.application(_:open:)` → `LinkInbox` (queue until `state` is attached, then `state.openLink`); `handlesExternalEvents(matching: [])` on the main `Window`.
- [ ] Test `LinkInbox` (queued before attach, flushed once, non-web URLs dropped). Commit.

### Task 5: Default browser row, release stamping

**Files:** Create `LittleWindow/DefaultBrowser.swift` (protocol `DefaultBrowserSystem` + real one over `NSWorkspace`); Modify `Settings/SettingsView.swift`, `scripts/release.sh`, `scripts/test-release.sh`.

- [ ] Tests with a fake system; `test-release.sh` checks the stamping helper adds http+https and that `Resources/Info.plist` has no `CFBundleURLTypes`. Commit.

### Task 6: Documents and whole-branch check

- [ ] `CLAUDE.md` (scope change, architecture, key decisions), `IDEAS.md` (left-out ideas), spec status. `scripts/test.sh` green. Fresh code review of the branch; fix what it finds.
