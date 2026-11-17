# Browser extensions, round 1 (design)

Owner decision, 2026-11-17: Singularity gets real browser extensions (WebExtensions through WebKit's
`WKWebExtension`), first for the simple cross-browser kind (Dark Reader, uBlock Origin Lite and the
like). Chrome Web Store's own button must work. The rest ("look further later") comes after.

Every call below that the owner did not make himself is marked **(builder's call)**.

## Why

The owner has come far enough with Singularity that he misses the extensions he uses elsewhere.
Singularity plugins stay (they do what extensions can't: 1Password through its CLI, the Assistant);
extensions are for everything that already exists as an extension.

## What the owner decided

- **Simple extensions first.** The 1Password spike of 2026-11-09 (Chrome-only APIs, Safari's
  app-extension messaging) stays a known limit; no shims for Chrome-only APIs in this round.
- **Per Space (approach A).** An extension is installed once on disk and switched on per Space,
  like plugins. Each Space has its own `WKWebExtensionController` with that Space's website data
  store, so an extension in "work" never sees "personal" tabs, cookies or storage, and its settings
  are per Space. (B, one controller for all Spaces as in Arc, was rejected: it breaks Space isolation.)
- **macOS 15.4 is the new minimum** (`WKWebExtension` needs it). Copies on macOS 14 stay on the last
  version that supported it (Sparkle reads the minimum from `Info.plist` into the appcast).
- **Chrome Web Store's button works**, plus a fallback button of our own in the address row.
- `.zip`, `.crx`, `.xpi` and unpacked folders can be added too.

## Spike results (2026-11-17, this branch, not kept)

- A per-Space controller (`WKWebExtensionController.Configuration(identifier: space.id)` with the
  Space's `WKWebsiteDataStore(forIdentifier:)`) injects content scripts into web views built by
  `WebViewRegistry.configuration(for:)`; `removeAllUserScripts()` (what `PluginScripts.rebuild`
  does) does not remove them; declarativeNetRequest blocks; unloading the context removes both.
- The controller must be on the configuration before the web view exists (setting it later on
  `webView.configuration` is a no-op). So **every web view of a Space gets the Space's controller**,
  and switching an extension on or off loads or unloads its context.
- Dark Reader 4.9.135 (Chrome MV3 zip) and uBlock Origin Lite (Chromium zip) load with no errors and
  have popups.
- Messaging from a content script to the background fails with "Tab not found" until the app
  answers WebKit's tab and window questions (`WKWebExtensionTab`, `WKWebExtensionWindow`, the
  controller delegate). So those are required, not optional.
- Chrome Web Store: with a Chrome user agent and a `chrome.webstorePrivate` stand-in the page still
  refuses (from Chrome 142 its decision `Rk` comes from Google's server, which reads client hints
  WebKit doesn't send). Emulating Chrome is a dead end. What works: a script in our own content
  world on `https://chromewebstore.google.com/detail/…` finds the store's disabled "Add to Chrome"
  button, renames it "Add to Singularity", enables it (again after every re-render, via a
  `MutationObserver`) and takes its click. The page keeps its "Switch to Chrome" banner.
- The `.crx` comes from
  `https://clients2.google.com/service/update2/crx?response=redirect&prodversion=<v>&acceptformat=crx2,crx3&x=id%3D<id>%26installsource%3Dondemand%26uc`
  (a redirect to `clients2.googleusercontent.com`), CRX3: `Cr24`, version 3, header length, a
  protobuf header, then a zip.

## Goals

1. Add an extension from Chrome Web Store (its own button, or the address row's), from a file
   (`.zip`, `.crx`, `.xpi`), from an unpacked folder, or by downloading a `.crx`/`.xpi`.
2. See what it asks for before it runs (an approval sheet), choose the Spaces it runs in.
3. It runs in that Space's web pages: content scripts, background, storage, declarativeNetRequest,
   its toolbar button with badge and popup, its options page, its context-menu items.
4. Turn it off per Space and per site; remove it; update a store extension by hand.

## Non-goals (this round)

- Chrome-only APIs or shims for them; native messaging; Safari app extensions.
- Automatic extension updates (a manual "Check for Update" only, see below).
- Keyboard shortcuts of extensions (`commands`), new-tab-page overrides, extensions in private windows
  (there are none), Firefox AMO's own install button (a downloaded `.xpi` is offered instead).
- Extensions in artifact tabs, notes, plugin tabs and terminals (**builder's call**: artifact pages
  carry `window.singularity` and are the owner's own files; plugin and note pages are locked hosts).

## Anti-goals

- An extension ever running in a Space it wasn't switched on for, or seeing another Space's tabs.
- Anything installed or changed without the owner pressing Install in our sheet. A page (the store
  included) can at most *open* that sheet.
- Agents getting a new way in: no MCP tool lists, adds or drives extensions; extension tabs are
  ordinary tabs to agents, nothing more.

## Design

### Where things live

- `~/Singularity/extensions/<id>/`: the unpacked extension (what WebKit loads). `<id>` is the Chrome
  id (32 letters a–p) for a store or `.crx` install, otherwise `local-<8 hex>`.
- `~/Singularity/extensions-state.json`: one record per extension (**builder's call**, next to
  `plugins-state.json`): id, name, version, source (`store` with its id, or `file`), the fingerprint
  of its folder at approval (`PluginFingerprint`, same rules: symlinks and hard links refused), the
  Spaces it's on, the WebKit context identifier per Space (so its storage survives restarts), the
  granted permissions and match patterns, install date.
- **Fifth known exception to "everything under `~/Singularity/`":** an extension's own storage
  (`chrome.storage`, its IndexedDB, its background page's data) lives where WebKit keeps a persistent
  controller's data, under `~/Library/WebKit/dev.roosa.Singularity/` keyed by the Space id. Deleting a
  Space or removing an extension removes it through `removeData(ofTypes:from:)`.
- Per site: `SiteSettings.disabledExtensions` (like `disabledPlugins`), applied as an explicit deny
  for that origin's match pattern in the Space's context.

### Adding

All sources end in the same place: a staged, unpacked folder → `WKWebExtension(resourceBaseURL:)` →
the approval sheet → on Install, an atomic move into `extensions/<id>/` and a record.

- **Unpacking** without a new dependency: `.crx` → strip and check the CRX3 header (Core
  `CRXFile`), then `/usr/bin/ditto -x -k` for the zip; `.zip`/`.xpi` → `ditto` directly; a folder is
  copied. Then `PluginFingerprint.listFiles` (refuses symlinks, hard links, odd files) and a
  `manifest.json` at the top (a zip with one top folder is accepted by descending into it).
- **CRX3 check (Core, tested):** parse the protobuf header, take `signed_header_data.crx_id`, require
  that it is the asked-for id (store) and that one `sha256_with_rsa` proof's public key hashes to it
  (`sha256(key)[0..<16]`, nibbles mapped to a–p), and verify that proof's RSA PKCS#1 v1.5 SHA-256
  signature over `"CRX3 SignedData\0" + le32(len) + signed_header_data + zip` with the Security
  framework. A file that fails is refused ("This extension file is damaged or not what it claims to be.").
- **Chrome Web Store page:** `StoreButtonScript` in its own `WKContentWorld`, only on
  `https://chromewebstore.google.com/detail/*`, does what the spike did and posts
  `{id}` on a click with `event.isTrusted`. The native side accepts it only from the main frame whose
  `securityOrigin` is `https://chromewebstore.google.com`, re-reads the id from the frame's URL, checks
  it is 32 letters a–p, and then downloads from the fixed URL above (host fixed in code, the id the
  only variable). The script is part of `PluginScripts`' base scripts so a rebuild keeps it.
- **Address-row fallback:** on a store detail page (Core `ChromeWebStore.extensionID(from:)`), an
  "Add to Singularity" button appears at the address row's right end, same download.
- **Download of a `.crx` or `.xpi`** (Firefox Add-ons' "Download file", any site): when it finishes,
  the sheet opens for it (**builder's call**). The file stays in Downloads.
- **Add Extension…** in Settings → Extensions and the palette: an open panel for a folder or file.
- **The sheet** (`ExtensionApprovalSheet`): icon, name, version, where it came from, what it asks for
  in plain words (each permission, the sites it can read and change: "all sites" said loudly), what
  WebKit can't do for it (`WKWebExtension.errors`, plus `context.unsupportedAPIs` once loaded) as a
  warning, and the Space switches (the current Space on, the others off; **builder's call**). Install /
  Cancel; no default button. Approving grants exactly the requested permissions and match patterns;
  optional ones are asked for at run time.

### Running

- `ExtensionCenter` (`state.extensions`, app side) owns one controller per Space, made with the
  Space's first web view (`WebViewRegistry.configuration(for:)` attaches it to web tabs, little
  windows and pop-ups; never artifact, plugin or note hosts), loads `WKWebExtension`s from
  `extensions/<id>/` once per launch, and a context per (extension, Space) where it's switched on and
  approved. Each context: `uniqueIdentifier` from the record (stable storage), the granted permissions
  and patterns, the per-site denies, `isInspectable` on (Safari's Develop menu can inspect it).
- **Changed on disk = paused.** At launch the folder's fingerprint is compared with the record's; a
  difference pauses the extension until it is approved again (the sheet lists it as an update).
- **Tabs and windows for WebKit:** each Space's web tabs (and its little windows) are
  `WKWebExtensionTab`s through a small adapter around `WebTabController`; the main window showing the
  Space is one `WKWebExtensionWindow` (its tabs: the Space's web tabs in sidebar order, the selected
  tab active), each little window another. Opening, closing, selecting, title and address changes are
  reported to the Space's controller. A tab of another Space is never handed to a controller.
  Extensions can open (`chrome.tabs.create`: a normal web tab in that Space), close, reload, navigate
  and select their Space's web tabs; they can't move them to other Spaces, pin them, or open new
  windows (refused; **builder's call**).
- **Toolbar buttons:** the address row gets one small button per extension that is loaded in the
  selected Space and has an action (icon from `action.icon(for:)`, badge text, disabled state); up to
  four, the rest in a "…" menu (**builder's call**). Click → `context.performAction(for: tab)`; a popup
  is shown with `action.popupPopover` from that button.
- **Options page:** `openOptionsPage` opens `context.optionsPageURL` as a tab in the Space.
- **Context menus:** the web view's right-click menu gets `context.menuItems(for: tab)` of the Space's
  loaded extensions (**builder's call**: cheap, many simple extensions use it).
- **Permission prompts at run time** (`promptForPermissions`, `…AccessToURLs`, `…MatchPatterns`): a
  sheet on the main window naming the extension and what it wants, Allow / Don't Allow, no default
  button; the answer is stored in the record and applied in that Space only.

### Turning off, removing, updating, Spaces

- **Settings → Extensions** (new pane): each extension with icon, name, version, source, status
  (running / paused: changed / failed to load), its Space switches, "Options…", "Check for Update"
  (store only: downloads the current `.crx`; a newer version goes through the sheet), "Remove".
  Add Extension… at the bottom.
- **Site settings panel:** a section "Extensions on this site" with a switch per extension that runs
  in this Space (off = denied for this origin).
- **Remove:** unload in every Space, remove its data records from each Space's controller, delete
  the folder and the record.
- **Deleting a Space:** before the website data store is removed, unload the Space's contexts, remove
  their data, drop the Space's controller (WebKit refuses to delete a store in use).
- **Clear Cookies & Site Data** (Data & privacy) also clears extension data in that Space
  (**builder's call**: the owner expects "everything of this Space").

### Scope and docs

- `CLAUDE.md`: the scope change (extensions are in, per Space, simple ones first; uBlock-style
  blocking by an extension the owner adds is fine, Singularity still builds no ad blocking of its
  own), macOS 15.4, the new folders, the fifth exception, and the "things to keep".
- `IDEAS.md`: move "Web-extension compatibility" out of "Decided against" into what's built, with
  what's still out (Chrome-only APIs, 1Password's extension).
- `Package.swift` `.macOS("15.4")`, `Resources/Info.plist` `LSMinimumSystemVersion` 15.4,
  `scripts/test-release.sh`'s expectation.

## Tests

- Core: `CRXFile` (a fixture `.crx` built in the test with a throwaway RSA key: good, wrong id,
  bad signature, truncated), `ChromeWebStore` (detail URLs → id, other URLs → nil, the download URL),
  the extensions-state file (round trip, tolerant decoding), the per-site deny.
- App (no network, no key window): a fixture MV3 extension (content script, background, DNR rule,
  popup) loaded through `ExtensionCenter` into a real `TestAppState` Space: the content script runs in
  that Space's tab and messages its background (proves the tab adapter), it does not run in a second
  Space, switching it off unloads it, a per-site deny stops it on that site, a changed file pauses it,
  deleting the Space removes its controller; the store script relabels and enables a fixture "Add to
  Chrome" button and posts only for a trusted click (a synthetic `.click()` is ignored).

## What's left to the builder

File layout inside `Sources/Singularity/Extensions/` and `Sources/SingularityCore/Extensions/`;
icon sizes; the exact wording of the sheet's permission lines; how the address row lays out the
buttons at narrow sidebar widths.
