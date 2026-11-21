# Browser extensions, Chrome compatibility (design)

Owner decision, 2026-11-21: Singularity adapts Chrome extensions that WebKit can't run as they are,
so that 1Password's own Chrome extension works. A general layer for every Chrome extension, plus a
small recipe for 1Password (owner's choice "2"); the adapted copy is kept apart from the original
the owner approved (owner's choice "A").

Builds on round 1 (`2026-11-17-extensions-design.md`, its "As built" section). Every call below that
the owner did not make himself is marked **(builder's call)**.

## Why

The owner wants 1Password's real extension in Singularity: fill and save logins, passkeys, the
toolbar popup, as in Chrome. Round 1 left Chrome-only APIs out, and the 1Password spike of
2026-11-09 said shims weren't enough. The spike of 2026-11-20/21 (scratch only, not kept) proved
otherwise:

- With stand-ins for the Chrome APIs WebKit lacks, 1Password 8.12.46.29's background starts, its
  popup and pages get answers, its content scripts reach the background.
- Signing in without the desktop app (account password + Secret Key, on
  `https://start.1password.com/signin/?auth-only=1`) adds and unlocks the account, and on github.com
  the inline menu filled the form and a passkey sign-in went through 1Password (owner, 2026-11-21).
- **WebKit bug found:** `new WebSocket(…)` in an extension's *service-worker* background never
  returns and freezes the whole background (timers stop, the popup gets no answers). A 10-line test
  extension shows it; the same code in a background *page* connects and exchanges messages.
  1Password opens its notifier WebSocket right after sign-in, so it froze there.
- What made 1Password work: (1) stand-ins, (2) rewriting its code's uses of APIs WebKit lacks,
  (3) running its background as a page, (4) one 1Password-specific change (below).

## What the owner decided

- **General layer for every Chrome extension, plus a 1Password recipe** (not a 1Password-only patch).
- **Approach A:** the original stays as approved and fingerprinted; Singularity builds an adapted
  copy from it, and WebKit loads that copy. A change to Singularity's adapting code rebuilds the copy
  without a new approval. If adapting a new 1Password version fails, the previous version keeps
  running and Settings says so.
- The service worker → page change happens **only when needed** (the background uses WebSocket, or
  a recipe asks for it); Dark Reader and uBlock Origin Lite, which work today, stay as they are.
- No trace or debug logging from the spike survives into the product.

## Goals

1. 1Password's Chrome extension installs from Chrome Web Store (its button or ours), and in a Space
   it's switched on for: sign-in without the desktop app, popup, inline fill, save prompts, passkeys.
2. Any Chrome extension that calls APIs WebKit lacks gets harmless stand-ins instead of a crash.
3. Any extension whose service-worker background uses WebSocket gets a working background.
4. Automatic store updates keep working: a new version is adapted before it replaces the old one;
   a version that can't be adapted is not installed, and the old one keeps running.
5. The owner sees, before Install, that and how Singularity adapts an extension.

## Non-goals

- 1Password's desktop app: unlock with the app or Touch ID. Its native host refuses Singularity
  (`BrowserVerificationFailed: UnknownBrowser`, 1Password's own allow-list). Only 1Password can
  change that. Native messaging stays refused, as in round 1.
- One sign-in for all Spaces. Each Space has its own controller and so its own extension storage
  (round 1's approach A); 1Password is signed in to and unlocked per Space. Sharing would mean one
  controller for all Spaces, which round 1 rejected because an extension would see every Space's tabs.
- Recipes for other extensions now (the format allows more later).
- Adapting Safari app extensions, or Firefox-only APIs.
- Replacing or changing the 1Password *plugin* (`Plugins/1password`); both may be installed.

## Anti-goals

- Weakening round 1's guarantees: nothing runs that the owner didn't approve, the adapted copy can't
  be changed on disk to run other code, an extension never runs in a Space it isn't on for.
- Any logging of what extensions send between their parts, page content, or form values. The spike
  logged message names; the product logs nothing per message.
- A stand-in that grants a capability WebKit or the owner didn't (no real downloads, idle detection,
  native messaging or browser-wide settings come out of a stand-in).
- Changing extensions that need nothing (they load from their original folder, byte for byte).
  An extension that does use a listed member gets the stand-ins and rewrite even if it ran before
  (uBlock Origin Lite may read `storage.managed`): the stand-ins only answer where WebKit had nothing,
  so it keeps working; its Settings row then says "Adapted" (**builder's call**). The owner's "stay
  as they are" is about the background change, which neither of them gets.

## Constraints (found in the spike; keep them)

- WebKit gives an extension a `chrome`/`browser` object (`chrome === browser`) whose existing
  namespaces can't be extended: a member added to `chrome.webNavigation` is silently ignored, and so
  is `Object.defineProperty`. A whole missing namespace (`chrome.idle`) *can* be added by assignment.
- Replacing `globalThis.chrome` (or `browser`) with a Proxy breaks every `runtime.sendMessage`
  delivery. So missing *members* can't be added at run time; the extension's own code must be
  rewritten to look them up elsewhere.
- An extension loaded from a relative file URL gets the app killed (SIGKILL, no output): always an
  absolute, standardised URL.
- A background page's module (`<script type="module">`) runs before the page's `load` event.
- Content-script ↔ background messaging needs the tab adapters round 1 already has.

## Design

### Where things live

- `~/Singularity/extensions/<id>/`: the original, unchanged (as today). Its fingerprint in the
  record is what the owner approved (as today).
- `~/Singularity/extensions-adapted/<id>/`: the adapted copy, made only for extensions that need one
  (**builder's call** on the name). WebKit loads this folder instead of the original.
- The record gains three optional fields (tolerant decoding, absent for extensions that need nothing):
  `adaptation` (the adapter version, `CompatAdapter.version`, a whole number bumped whenever the
  adapting code's output changes), `adaptedFingerprint` (`PluginFingerprint` of the adapted folder),
  and `adaptationSummary` (what was done, for the sheet and Settings: the number of stand-ins, the
  background change, the recipe's name).

### The adapter (Core, pure, tested)

`CompatAdapter.adapt(original:, into:, extensionID:)` (in `SingularityCore/Extensions/`, name the
builder's) copies the original and changes the copy. It needs no WebKit. Its output is a function of
the original files, the extension id and the adapter version only, so the same input always gives
the same folder. Steps, each only when it applies:

1. **Missing-member rewrite.** In every `.js` file, each use of `chrome.<ns>.<member>` or
   `browser.<ns>.<member>` from a fixed list of members WebKit lacks becomes `__sg.<ns>.<member>`.
   Pattern-based on whole identifiers (no rewrite inside a longer name; strings and comments may be
   rewritten too, harmless). The list from the spike:
   `webNavigation.onCreatedNavigationTarget/onHistoryStateUpdated/onReferenceFragmentUpdated/onTabReplaced`,
   `webRequest.onAuthRequired/onBeforeRedirect/onSendHeaders/onResponseStarted`,
   `runtime.requestUpdateCheck/onSuspend/onMessageExternal/onConnectExternal/onUpdateAvailable/onRestartRequired`,
   `permissions.addHostAccessRequest/removeHostAccessRequest`, `action.getUserSettings`,
   `storage.managed`, `windows.onFocusChanged/onCreated`. The list is data in Core. The builder
   checks it against the current macOS's WebKit and drops what WebKit has; a member WebKit gains
   later does no harm, because inside `__sg` the real member always wins over the stand-in
   (**builder's call**: no macOS 15.4 machine is needed).
   **Only real uses count** (**builder's call**): a member access in code, not text inside strings
   or comments, so an extension that merely names one isn't adapted.
   **The rewrite is safe on its own** (**builder's call**): a use becomes
   `(globalThis.__sg ?? chrome).<ns>.<member>` (or `browser`, as written), so code that runs without
   the stand-ins file (a file the extension injects later with `scripting.executeScript` or
   `registerContentScripts`) behaves exactly as the original did instead of throwing. Such injected
   files don't get the stand-ins file added.
2. **Stand-ins file.** `sg-compat.js` at the folder's top: defines `globalThis.__sg` (a Proxy that
   answers a namespace with the real one merged with the stand-ins, functions bound to the real
   object) and assigns whole missing namespaces onto the real `chrome` (`idle`, `management`,
   `privacy`, `downloads`, `notifications`, when missing). Stand-ins answer as Chrome does when the
   feature is off or empty: events that never fire; `idle.queryState` → `"active"`;
   `management.getSelf` → this extension's own manifest data, `getAll` → only itself, `setEnabled`
   refused; `privacy.services.*.get` → `{value: false}`, `set` refused; `downloads.download` refused
   with an error; `notifications.create` → resolves without showing anything (**builder's call**:
   showing them is a later step); `runtime.requestUpdateCheck` → `"no_update"`;
   `permissions.add/removeHostAccessRequest` → resolve; `action.getUserSettings` →
   `{isOnToolbar: true}`; `storage.managed.get` → `{}`. Both callback and promise forms. No logging.
   It is loaded first everywhere the extension runs code: inserted first in each `content_scripts`
   `js` list, first in each extension HTML page's `<head>`, and imported/loaded first by the
   background (module or classic, matching the original).
3. **Background as a page**, when the service-worker code (its file and the files it imports)
   constructs a WebSocket (`new WebSocket`, not a mention in a string or comment; **builder's
   call**), or a recipe asks for it: the manifest's `background` becomes
   `{"page": "<generated>.html", "persistent": false}`, the page loads the original worker file
   (`<script type="module">` when `type` was `module`, else a classic script plus anything it
   `importScripts`, **builder's call** how far to go for `importScripts`; 1Password is a module).
4. **The recipe**, if the extension id has one (below).
5. The manifest's `update_url` is dropped (WebKit doesn't use it; updates are ours), `_metadata/`
   is dropped (Chrome's verified-contents hashes no longer match the copy), nothing else in the
   manifest changes: **the adapted manifest asks for exactly the permissions and match patterns of
   the original**, checked by the adapter (it fails otherwise).

If no step applies, there is no adapted copy and the extension loads from its original folder.

### Recipes

A recipe is data in Core, keyed by Chrome id: a name ("1Password"), whether the background must be a
page, and a list of text replacements, each a regular expression with the exact number of matches
it must find (a different count fails the whole adaptation; minified names change every release,
so patterns match the code's shape, not its names). Tested against small fixtures, and opt-in
against a real `.crx` (`SG_REAL_CRX`, as round 1).

**1Password** (`aeblfdkhhhdcdjpifhhbdiojplfjncoa`): background as a page; and its "Chrome MV3 means
service worker" check, a function of the form `function X(){return Y()&&Z()}` used to choose between
`clients.matchAll`/`OffscreenCanvas`/`data:` paths and the page paths, gets
`&&typeof ServiceWorkerGlobalScope!=="undefined"` added, so it takes its Firefox-style page paths.
The builder finds a pattern that matches that check (and only it) in 8.12.46.29 *and* in the version
the store serves when the work starts (both downloaded by id through the existing store download;
the spike's copy was scratch and may be gone), and the opt-in real test guards it. Nothing else of
1Password's code is changed by the recipe. 1Password's files are never committed: the opt-in test
always runs on a `.crx` the person running it supplies (**builder's call**).

### When adapting happens

- **Install (sheet):** after staging and the CRX3 check, before the sheet. The sheet shows the
  original's permissions as today and, when there is an adaptation, one line: "Singularity adapts
  this extension to run here: stand-ins for N Chrome features, background as a page, 1Password
  recipe." (**builder's call** on wording; only the parts that apply.) If adapting fails the sheet
  still opens, says the extension can't be adapted, and Install is off (**builder's call**). On
  Install, original and adapted copy move into place together; both fingerprints are recorded.
- **Launch:** for each extension whose record has an adaptation: if `adaptation` is the current
  adapter version and the adapted folder's fingerprint matches `adaptedFingerprint`, load it. Else
  rebuild it from the original (which must still match its own fingerprint, as today) into a new
  folder, swap it in, record the new fingerprint and version, load it. An extension that didn't need
  adapting but does with the current adapter (a new list entry, a new recipe) is adapted the same
  way at launch, without a sheet: the original, its permissions and the approval are unchanged.
  If rebuilding fails, the old adapted copy keeps running if it still matches its recorded
  fingerprint, and Settings → Extensions shows "Couldn't be adapted by this version of Singularity;
  the previous adaptation is running." With no usable old copy it is paused with that reason.
- **Automatic update:** the new version is adapted in staging. Fails → the update is dropped, the
  old version keeps running, Settings shows "Version X couldn't be adapted; version Y is running."
  (checked again at the next update check). Succeeds → installed as today (silently when it asks
  for nothing new, else the sheet).
- The adapted folder is written with the same care as the original: built in the staging folder,
  moved into place atomically, `PluginFingerprint.listFiles` rules (no links).

### Settings → Extensions

Each adapted extension's row says "Adapted: …" (the summary) under its status, and the failure
lines above when they apply. Nothing to switch: adapting isn't optional (**builder's call**; without
it these extensions don't run).

### Scope and docs

- `CLAUDE.md`: in the extensions part, the compat layer and its "things to keep" (the constraints
  above, the adapted folder and its fingerprint, recipes as data with exact match counts, no logging).
- `IDEAS.md`: "Extensions, round 2" no longer lists shims for Chrome-only APIs; 1Password's desktop
  app unlock stays listed as needing 1Password.

## Tests

- Core: the rewrite (whole-identifier matches only, each listed member, nothing else touched); the
  stand-ins file is inserted first in content scripts, pages and the background; the background
  change only with WebSocket or a recipe, for module and classic workers; permissions unchanged;
  same input → same output; a recipe with the wrong match count fails; record round trip with and
  without the new fields; the launch decision (current/old version, fingerprint match/mismatch).
- App (no network, no key window): a fixture MV3 extension whose service worker opens a WebSocket
  to a local test server and whose code uses a missing member: adapted at install, its background
  connects and still answers its content script in a `TestAppState` Space; a fixture that needs
  nothing loads from its original folder; a changed adapted file is rebuilt at launch; an adapter
  failure during an update keeps the old version.
- Opt-in: `SG_REAL_CRX=<1Password .crx>:aeblfdkhhhdcdjpifhhbdiojplfjncoa`: the 1Password recipe
  applies with its exact counts and the adapted copy loads in WebKit without errors.
- By hand (the owner): 1Password from the store button, sign in in one Space, fill and a passkey on a
  real site, the popup; Dark Reader and uBlock Origin Lite unchanged.

## What's left to the builder

File and type names; exactly how the rewrite recognises a use (as long as the Core tests hold); the
generated page's name; the summary's wording; how `importScripts` is followed for classic workers.

## As built (2026-11-21)

Overrides the design where they differ. Plan: `docs/superpowers/plans/2026-11-21-extension-compat.md`.

- **Rewrite form:** a use becomes `Object(globalThis.__sg||chrome).<ns>.<member>` (`browser` when written so), not
  `(globalThis.__sg ?? chrome)`: a replacement starting with `(` can join the previous line through ASI, and one with
  quotes would turn a masking mistake inside a string into a syntax error. `?.` between the parts is matched too.
- **Whole missing namespaces** (`idle`, `management`, `privacy`, `downloads`, `notifications`): a real use adds the
  stand-ins file, no rewrite (they can be assigned onto `chrome`).
- **`adaptation` is recorded also when nothing was needed** (`adaptedFingerprint` nil), so launch doesn't scan every
  extension again; any adapter version bump re-checks them all.
- **Stand-ins for a worker that stays a worker:** `<worker dir>/sg-worker.js` loads `/sg-compat.js` first, then the
  original (`import` for a module worker, `importScripts` for a classic one), so relative loads resolve as before.
  The background page is `<worker dir>/sg-background.html`; for a classic worker it lists the literal `importScripts`
  arguments before the worker and defines a no-op `importScripts`.
- **MAIN-world content scripts** don't get `sg-compat.js`; every `.html`/`.htm` file gets it right after `<head…>`.
- **Stand-in answers:** `privacy.services.*.get` → `{value: false, levelOfControl: "not_controllable"}` (`set`/`clear`
  refuse), `management.setEnabled` and `downloads.download` refuse, `notifications.create` resolves an id and shows
  nothing, `notifications.getPermissionLevel` → `"granted"`.
- **Checked with the real 1Password 8.12.46.29** (still what the store serves on 2026-11-21): the masked rewrite finds
  exactly the uses a plain text search finds (21 in `background/background.js`, 3 in one popup chunk), the same
  12 members the spike rewrote; the recipe pattern matches once. In a test Space the adapted copy's background loads
  without a missing-API error and its popup renders; its remaining errors (a match pattern with the test page's port,
  native messaging refused, core calls before its WASM is ready) are exactly those of the spike's working copy, with
  which the owner signed in, filled and used a passkey.
- **Test seam:** `ExtensionCenter.testAdapter` (the adapter a new centre starts with; adapting happens at launch) and
  `adapter`.
- **Not done:** notifications are not shown; no other recipes.
