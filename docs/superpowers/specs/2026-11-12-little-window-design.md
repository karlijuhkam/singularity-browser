# Little windows for links from other apps: design

Date: 2026-11-12. Status: draft, waiting for the owner's approval.

**When:** not before the updates project (`2026-11-12-updates-design.md`) is finished and the
owner's daily copy runs from `/Applications` (owner decision, 2026-11-12: "let's wait for the
installed copy and the update work to finish"). See "Which copy receives links".

## Why

The owner uses Singularity as the daily browser. A link clicked in Slack or Mail usually needs one
look: often the page has served its purpose after that and should leave nothing behind; sometimes
it is the start of real work and belongs in a Space, and not always the Space that happens to be
open.

The owner's words: "it should first open the page in a throwaway window, where it's possible to
choose which space to open (default option is the currently open space)". "When I don't want to
keep it I'll just close it." "If it's something I am going to keep working on I want to open it
fully in a space." On logins: "current space logins, reload if I pick another space". On several
links: "another little window". What would be wrong: "if it reuses the little window if it should
be another".

Today Singularity cannot receive links at all: `Resources/Info.plist` declares no URL schemes and
the app has no open-URL handler, so macOS does not offer it as a default browser. That is part of
this work.

**This is a scope change by the owner.** `CLAUDE.md` lists "Peek/Little Arc-style windows" as out
of scope, and the onboarding design left out "Set as default browser". Both lines are updated when
this is built (see "Documents").

## What success looks like

1. Singularity is the default browser. The owner clicks a link in Slack. A small Singularity window
   opens in front with that page, logged in as the Space that was open. No tab appeared anywhere.
2. The owner reads, scrolls, clicks, types, logs in. Then either:
   - closes the window (red button or ⌘W): the page is gone, no tab, no history entry; or
   - presses "Open in Work" (⌘O): the little window closes, the main window comes forward, and the
     same live page is now a tab in Work, selected. Nothing reloaded; a half-filled form is intact; or
   - picks "Personal" in the Space menu, then "Open in Personal": the main window switches to
     Personal and loads the address in a new tab there, with Personal's logins.
3. A second link clicked while the first little window is still open gets its own little window.

## Goals

- Singularity can be chosen as the default browser (http and https links).
- Every link from outside opens in its own little window. Never a reused one.
- The page in a little window is a normal, fully working page of the current Space.
- One action moves it into a Space; the default is the Space it was opened with.
- Closing leaves nothing behind in the Space.

## Non-goals

- Little windows for links clicked *inside* Singularity (web tabs, terminal tabs, artifact pages).
  Those behave as today.
- A setting to skip the little window and open links straight in a tab.
- Anything in the welcome flow about the default browser.
- Opening local files (`file:`, `.html` from Finder). Only `http` and `https`.
- Restoring little windows after quit. They are throwaway.
- Agents seeing or driving little windows.
- An editable address field, a site settings button, tabs or splits in a little window.
- Remembering the little window's size or position.

## Anti-goals (a failure even if it works)

- A second link loading into an existing little window.
- A link from outside silently adding a tab to a Space.
- A closed little window leaving a history entry or a tab.
- ⌘W in a little window closing a tab of the main window.

## Behaviour

### Receiving a link

- `Info.plist` declares the `http` and `https` URL schemes (`CFBundleURLTypes`), which is what
  makes macOS list the app under System Settings → Desktop & Dock → Default web browser. The
  builder verifies on a built bundle whether macOS also wants an HTML document type for that list
  and adds only what is needed. No other scheme or file type is claimed.
- `AppDelegate` receives the URLs (`application(_:open:)`). Each http/https URL opens one little
  window. Anything else is ignored.
- **Which Space:** the Space selected in the main window at that moment (`AppState.selectedSpaceID`;
  the first Space if none is selected). It is fixed for that little window from then on, even if
  the owner switches Spaces in the main window. Called the window's *home Space* below.
- **App not running:** macOS starts Singularity. The main window opens as on any launch; the
  little window opens in front of it and is the key window. URLs that arrive before `AppState` is
  reachable from the delegate are queued and opened once it is (today `appDelegate.state` is set in
  `MainView.onAppear`).
- **App running:** macOS activates Singularity; the little window is in front and key. That the
  main window may also rise behind it is normal macOS behaviour and accepted. SwiftUI must not
  react to the URL by itself (opening or re-selecting the main `Window` scene); if it does, switch
  that off (`handlesExternalEvents(matching: [])` on the scene is the usual way; verify).
- **Welcome flow open:** the little window still opens. The flow stays as it is until the owner
  opens the page in a Space (that goes through `showTab`, which closes the flow).
- **A second copy** started by macOS for a link cannot happen in normal use (one bundle, and
  `InstanceLock` already hands over to the running copy). Nothing new here.

### Which copy receives links

Every bundle built from this repository has the bundle id `dev.roosa.Singularity`. If several of
them claim web links, macOS may hand a link to a copy that is not the running one; that copy fails
`InstanceLock`, activates the other and exits before it has a delegate, and the link is lost.
So exactly one kind of bundle claims links:

- **Release builds only.** `scripts/release.sh` produces the bundle with `CFBundleURLTypes`.
  `scripts/build-app.sh` produces it without (the builder picks how: the entry kept out of
  `Resources/Info.plist` and added by `release.sh`, or removed by `build-app.sh`). So `build/`,
  test bundles under `/private/tmp` and worktree builds are never candidates.
- The code that receives links and opens little windows is in every build; app tests call it
  directly.
- The owner decided against a switch that would let `build/` take links in the meantime.
- The Settings row decides "is Singularity the default" by bundle id, not by path. If the default
  is a Singularity at a different path than the running copy, the row says so and names that path.
  A build that does not claim links (no `CFBundleURLTypes` in its own Info.plist) shows no button
  and says that only the installed release can be the default browser.

### The window

Layout A from the brainstorm mockup (`.superpowers/brainstorm/15657-1794483926/content/little-window.html`):

```
┌──────────────────────────────────────────────────────────────────────┐
│ ● ● ●        github.com/roosa/singularity/pull/42   [● Work ▾] [Open in Work ⌘O] │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│                         the page                                     │
│                                                                      │
└──────────────────────────────────────────────────────────────────────┘
```

- An ordinary, resizable macOS window with the standard traffic lights. About 1000 × 700, centred
  on the screen the pointer is on; each further little window is offset a little from the previous
  one so none hides another completely.
- **Address** in the middle: host and path of the current page, read-only, truncated in the
  middle when long. It follows navigation. The window's title (Mission Control, Window menu) is the
  page title.
- **Space menu:** a pill with the Space's colour dot and name. The menu lists every Space in rail
  order with its dot; the home Space is marked "current". It starts on the home Space. Choosing
  another changes only what the button will do; nothing reloads until the button is pressed.
- **Open button:** "Open in <Space name>", ⌘O. The default action of the window.
- A thin loading bar like the main window's while the page loads.
- The title bar still drags the window, and the two controls still take clicks. `CLAUDE.md`'s
  split-view notes apply (macOS starts a window drag in the title-bar strip before asking the
  view; never put SwiftUI `.help()` on chrome there). An `NSToolbar` or a title-bar accessory
  avoids the problem; the builder picks.
- Looks like the rest of the app (same fonts, colours, light/dark). No new visual language.

### The page

It is a normal web page of the home Space:

- The Space's data store (cookies, logins), user agent, and plugin page scripts (so 1Password can
  fill a login), the Space's per-site settings (camera/microphone, plugins off for a site).
- Downloads, HTTP login dialogs, page alerts, file pickers, Inspect Element, pinch zoom and
  two-finger back/forward work as in a tab. Dialogs are sheets on the little window.
- **Links** load in the same little window. So do links and scripts that ask for a new tab or
  window (`target="_blank"`, `window.open`): the address is loaded in the same window and no pop-up
  is created. Known limit: a sign-in that depends on a pop-up talking back to its opener will not
  complete in a little window; open the page in a Space for that.
- **⌘-click** on a link opens it as a background tab at the end of the home Space (in a tab it
  goes right after that tab; a little window has no place in the list, and `openInBackgroundTab`
  already appends when the source id is unknown). The little window stays.
- **A link that never becomes a page** (a zip, dmg or ics; `Content-Disposition: attachment`):
  the download starts as usual and shows in the main window's Downloads list. If the little
  window has shown no page yet, it closes itself once the download has started. If a page was
  already showing, it stays.
- `window.close()` from the page closes the little window.
- Non-web links (`mailto:`, `zoommtg:` …) go to the system, as in a tab.
- A failed load shows the usual error page; Reload retries.
- **Not recorded:** no history entry and no favicon file while the page is in a little window.
  Nothing is written to `space.json` (not even an unchanged rewrite).
- **Agents:** the page is in no Space's tab list, so no agent tool can list, read or act on it, and
  `read_console` / `read_network` capture nothing for it.

### Menu commands while a little window is the key window

- ⌘W closes the little window. Never a tab.
- ⌘O opens it in the chosen Space.
- Reload, Back, Forward, Find / Find Next / Find Previous, Zoom In / Out / Actual Size and Print
  act on the little window's page.
- Commands that act on the main window's tab, sidebar or layout are disabled: Next/Previous Tab,
  the split commands, New Folder, Open Location (⌘L).
- Commands that go somewhere in the main window keep working and bring the main window forward:
  New Tab / Command Palette, New Terminal, New Space, picking a Space (⌘1…⌘9), Settings, Welcome.
  The little window stays open behind.

This is the same idea as `welcomeCoversWindow` in `Commands.swift`: the menu asks `AppState` what
is in front.

### Opening it in a Space

**The home Space (default).** The live page moves; nothing reloads.

- A web tab is appended to the home Space with the page's current address and title, and selected.
- The same `WKWebView` (scroll position, form input, back/forward list, media) becomes that tab's
  view.
- The current page gets its history entry and its favicon now (both were skipped while little).
- The little window closes; the main window comes forward showing the home Space and the tab
  (`showTab`, so the welcome flow closes too). If the main window was closed, it is opened again
  *before* the little window closes (otherwise the last window closes and the app quits).
- From here on it is an ordinary tab: agents can see it if the Space allows agents, pop-ups open as
  tabs, visits are recorded.

**Another Space.** Logins cannot move between Spaces, so the page is loaded again there.

- The little window's page is torn down and the window closes.
- A new web tab with the page's current address (the one showing, not the one first clicked) is
  opened and selected in the chosen Space, and the main window switches to that Space
  (`userSelectSpace` + `openInNewTab`, or equivalent).
- Form input and anything else on the page is lost. No warning is shown: the owner chose this.
- If the page was showing a load error, the failed address is what gets opened.

### Closing

- Red button, ⌘W or `window.close()`: the web view is torn down, nothing is kept. No confirmation,
  even with form input.
- Quitting the app closes all little windows without asking and does not restore them. Little
  windows do not count for the quit confirmation (that is about terminals).
- The home Space is deleted while a little window of it is open: the window closes and its
  controller is removed as part of `deleteSpace`, before the Space's WebKit data store is removed
  (that removal fails while a web view still uses the store). `deleteSpace` removes controllers by
  the Space's tab ids today, so it must also ask for the little ones.
- Closing the main window while little windows are open does not quit the app
  (`applicationShouldTerminateAfterLastWindowClosed` already waits for the last window); closing
  the last window of any kind quits, as today.

### Default browser in Settings

Settings → General gets one row, "Default browser":

- When Singularity is the default: the text "Singularity is your default browser."
- Otherwise: a button "Make Default…". It asks macOS
  (`NSWorkspace.setDefaultApplication(at:toOpenURLsWithScheme:)` for `http`; macOS shows its own
  confirmation and moves `https` with it; verify the exact behaviour on macOS 14 and current). The
  row re-reads the state when the Settings window becomes key, since the owner answers a system
  dialog or changes it in System Settings.
- Status is read with `NSWorkspace.urlForApplication(toOpen:)` for an `https` URL, compared with
  the running bundle.
- No button for a copy that cannot be the default: a bare debug binary, a build that does not
  claim links (see "Which copy receives links"), or a translocated app (`AgentConnect` already has
  the translocation rule). The row then says why.

## How it fits the code

Decided here, because they keep the change small and follow what exists:

- **One registry.** A little window's `WebTabController` lives in `WebViewRegistry` like any other,
  under a fresh tab id and its home Space's id, built with the same `configuration(for:)` +
  `pluginScripts.attach`. So content-script rebuilds, `tabID(for:)` (plugin page messages) and
  `controllers(in:)` cover it for free. What makes it "little" is only that no `BrowserTab` with
  that id exists in the Space.
- **Moving into the home Space** is then: add a `BrowserTab` with that same id
  (`BrowserTab.init(id:kind:…)` takes one; only the `.web(_:title:)` shortcut doesn't), select it, let the pane take the web view (`HostedView` moves a view
  to its newest container; the little window must give it up and close without `tearDown`).
- **`WebTabController` needs to know it is little**, a flag that is switched off on the move:
  - `recordVisit` is skipped while little;
  - `createWebViewWith` returns nil and loads the request in the same view while little;
  - `webViewDidClose` closes the little window, not `closeTab`;
  - title/address changes must not reach `webTabDidChange` while little: it would find no tab, but
    `mutateSpace` still marks the Space dirty and rewrites `space.json`. The little window needs
    title, address and progress itself (the controller's observed properties, or its own
    observation of the web view);
  - `fetchFavicon` is skipped while little (it writes into `spaces/<slug>/favicons/`) and run at
    the move.
- **Agent approval sheets** stay on the browser window: `AgentApprovals.presentingWindow` uses
  `NSApp.mainWindow` today, which would be a little window when one is in front. Pin it to the
  main browser window.
- **The main browser window must be reachable from code**: to bring it forward, and to open it
  again when it was closed. Nothing does that today (it is a SwiftUI `Window` scene; no
  `openWindow`, no `applicationShouldHandleReopen`, nobody holds the `NSWindow`). Settle this in
  the first task: opening in a Space and "New Tab / palette / ⌘1…⌘9 bring the main window forward"
  both depend on it.
- **Console/network capture:** `CaptureBridge` must drop messages from a little controller, even
  on a site that is switched on, since no agent can read them and they would sit in memory.
- **Windows** are plain AppKit (`NSWindow` + a small controller hosting SwiftUI for the chrome),
  owned by one object on `AppState` (e.g. `LittleWindows`) that knows the open windows, the key one
  (for the menu) and closes them when a Space is deleted. Suggested place:
  `Sources/Singularity/LittleWindow/`.
- **Core, pure and unit-tested** (`SingularityCore`, e.g. `Web/LittleWindow.swift`): which incoming
  URLs are accepted; the address text shown (host + path, truncation left to the view); which Space
  is the home Space; "move or reload" for a chosen Space; which address a reload opens (current,
  or the failed one).
- **Default-browser calls** go through a small protocol (as `AgentShell` does for Connect) so tests
  pass a fake.

Left to the builder: names, the exact window chrome technique, sizes and offsets, how the menu
learns which window is key, how queued launch URLs are held.

## Constraints

- No new dependency. AppKit + WebKit + SwiftUI only.
- `dev.roosa.Singularity` stays the bundle id.
- Boring, commented Swift; comment the AppKit window and URL-event parts.
- **Never call the real "make default" in tests or trials.** Tests use the fake. In a running test
  copy nobody clicks "Make Default…": it would change the owner's Mac.
- **Never send a link through macOS in a test or trial** (`open https://…`): it goes to the
  owner's default browser, which is the owner's daily copy once this ships. Tests call the app's
  own entry point (the function the delegate calls) directly. Test bundles come from
  `build-app.sh`, so they do not claim links. The real check (System Settings list, a click in
  Slack) is the owner's, with the installed release.
- Test copies must not take focus: app tests keep little windows off screen, like the other
  `AppTests` suites, and never activate the app.

## Tests

Core (Swift Testing): the rules listed under "Core".

App tests (`Tests/SingularityAppTests`, nested in `AppTests`, real `AppState` via
`TestAppState.make`, a local fixture site):

- a link opens a controller that is in no Space's tabs; two links give two windows and two web views;
- after the page loads, the Space's history has no entry and `space.json` has no new tab;
- open in the home Space: the tab exists with the same id, its view is the *same* `WKWebView`
  object, it is selected, the history entry is there, the little window is gone;
- open in another Space: a new tab with the current address in that Space, that Space selected,
  the old web view torn down, nothing added to the home Space;
- closing: controller removed, nothing in the Space;
- a `target="_blank"` link loads in the same view and adds no tab;
- ⌘W routing: with a little window in front, the close command closes it and the main window's
  selected tab is still there;
- deleting the home Space closes its little windows;
- the Settings row with a fake: default / not default / not an installed bundle.

By hand, by the owner, with the installed copy: choose Singularity in System Settings; click links
in Slack and Mail, running and not running; 1Password fills in a little window; the three ways out.

## Documents

When built, `CLAUDE.md` changes:

- remove "Peek/Little Arc-style windows" from the out-of-scope list and add a "Scope change (owner
  decision, 2026-11-12)" line for little windows and default-browser registration;
- architecture: the new folder and Core file;
- a "Little windows" entry under Key decisions with the things that would bite later (one
  registry and the missing `BrowserTab`; the little flag; the LaunchServices warning for test
  bundles; never click "Make Default…" in a test copy).

`IDEAS.md`, "New, not yet decided", gets the ideas this design leaves out, so they are not lost: a
setting to skip the little window; little windows for links inside Singularity (Peek); pop-up
sign-in inside a little window.

## My calls (not said by the owner; approved as a list in the brainstorm, or made while writing)

Approved as a list: home Space fixed at click time; app-not-running behaviour; links and new-tab
links stay in the same window; the Space's plugins and site settings apply; no history until
opened in a Space; invisible to agents; ⌘O / ⌘W; not restored; Settings → General button, nothing
in the welcome flow; no skip setting; in-app links unchanged.

Made while writing, please check:

1. Opening in the home Space moves the live page without a reload, and the little window closes.
2. Opening in another Space opens the address *currently showing*, without a warning about lost input.
3. ⌘-click in a little window opens a background tab in the home Space.
4. Closing never asks, even with form input.
5. The address is read-only; no back/forward buttons in the title bar (swipe and the menu shortcuts work).
6. While a little window is in front, Reload/Find/Zoom/Print/Back/Forward act on it; tab, split
   and sidebar commands are off; New Tab, the palette and Space switching still work and bring the
   main window forward.
7. Only http/https; local HTML files are not claimed.
8. Pop-up-based sign-in does not work in a little window (known limit).
9. Deleting a Space closes its little windows.
10. A link that is a download closes its (empty) little window once the download has started.
11. Agent approval sheets always appear on the main browser window, never on a little window.
12. The Settings row compares by bundle id and names the path when another copy is the default.
