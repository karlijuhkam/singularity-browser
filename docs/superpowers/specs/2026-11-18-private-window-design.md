# Private windows: design

Date: 2026-11-18. Status: built 2026-11-18. Asked for by the owner ("privaatne aken, kirjuta disain ning arenda see",
after "we don't have an incognito mode"), who chose a private *window* over a temporary Space. Every
other call below was the builder's; the owner reviews them after the release.

## Why

There is no way to look at a page without it leaving something behind: every page belongs to a
Space, and a Space keeps cookies, logins, site data, history and favicons. Little windows don't
help: they are throwaway, but they use the home Space's logins and data store, so a login made
there stays in the Space.

## What success looks like

1. ⇧⌘N (File → New Private Window, or "New Private Window" in the palette) opens a window marked
   **Private**, with the address field focused and a short note on what the window keeps.
2. The owner types an address or a search, logs in somewhere, opens a pop-up sign-in, follows links.
3. The owner closes the window. Nothing of it is anywhere: no history entry, no favicon, no tab, no
   cookie in any Space's store, nothing under `~/Singularity/` changed (except a downloaded file,
   which is in `~/Downloads`, where the owner asked it to go).
4. Opening a second private window while the first is open shares the first one's logins (like
   other browsers' private sessions). Once the last private window is closed, the next one starts
   logged out.

## Goals

- A window whose page has its own **in-memory** WebKit data store (`WKWebsiteDataStore.nonPersistent()`),
  shared by the private windows open at the same time and dropped when the last one closes.
- An editable address field (address or search, with the search engine from Settings), Back,
  Forward, Reload.
- Pop-ups (`target="_blank"`, `window.open`) and ⌘-click open in a new private window that shares
  the store, so a sign-in pop-up can talk to its opener.
- The page commands of the menu (Find, Reload, Back, Forward, Zoom, Print) act on it while it is in
  front; ⌘W closes it; ⌘L puts the cursor in its address field.

## Non-goals (the builder's calls)

- **Tabs in a private window.** One page per window. ⇧⌘N again for another; ⌘T still means a new
  tab in the browser window.
- **A private Space** (the other option the owner was offered).
- **Moving a private page into a Space.** It would have to load again with the Space's logins, and
  the point of the window is that nothing leaves it.
- **Agents, plugins, browser extensions, the page agent, console and network capture, site
  settings.** None of them is attached to a private page. No agent tool can list or reach it (it is
  in no Space and not in `WebViewRegistry`).
- Restoring private windows after a quit or a crash.
- A setting to open links from other apps in a private window.
- A lock, a timeout or a "private by default" setting.

## Anti-goals (a failure even if it works)

- Anything a private page did reaching a Space's data store, history, favicons, `space.json` or
  `state.json`.
- A private page reachable by an agent, a plugin or an extension.
- The private data store outliving the last private window.

## How it works

### Data store

`PrivateWindows` holds one `WKWebsiteDataStore.nonPersistent()` while at least one private window
is open. Every private page and pop-up is made with a configuration that uses it. When the last
private window closes, the store is emptied (`removeData` of every type, best effort) and the
reference dropped, so the next private window gets a fresh one. A download still running keeps its
page's controller (and so the store) alive until it ends, as it does for tabs and little windows;
the next private window gets a new store all the same.

The configuration is the browser's (Safari user-agent suffix, full screen, Inspect Element) with
nothing else: no `PageAgentScript`, no plugin scripts, no extension controller, no capture.

### The page

An ordinary `WebTabController` made with `isPrivate: true`, owned by its window, never put in
`WebViewRegistry`. Its `spaceID` is a fresh UUID that names no Space. Because it is private:

- no `webTabDidChange`, no history entry, no favicon file, no `recordVisit`;
- a `.crx`/`.zip` download is not offered to the extensions (`ExtensionCenter.add`);
- a pop-up, `target="_blank"` or ⌘-click opens a new private window (a pop-up hosts the web view
  WebKit made from the opener's configuration, so `window.opener` works);
- `window.close()` closes its window; a pop-up whose first response turned out to be a download
  closes too (it would stay empty);
- camera and microphone: WebKit's own question every time (there are no site settings without a
  Space);
- page dialogs and HTTP logins work as in a tab (the window is on screen).

Downloads land in `~/Downloads` and are listed in the sidebar's downloads list of this run (in
memory, as every download). That is the one place a private download shows, and only by its file
name.

### The window

`PrivateWindow` / `PrivateWindows` (`Sources/Singularity/PrivateWindow/`), modelled on little
windows: an `NSWindow` (not released when closed, tabbing off), an `NSToolbar` (`PrivateWindowChrome`)
with Back, Forward, Reload, the address field in the middle and a "Private" mark at the right, and
the page under it. A new window with no page shows a native note instead of the empty web view:

> **Private window**
> Pages you open here keep no history, and their cookies and site data live only in memory, until
> the last private window is closed. Downloads stay in your Downloads folder. Agents, plugins and
> extensions can't see this window.

Closing frees: the window's content view, toolbar and chrome are dismantled, the controller torn
down, the window ordered out (never `close()` from code: closing the last window quits the app).

### Address field

Pure rules in Core, `PrivateWindowRules`:
- `destination(typed:searchTemplate:)`: the typed text through `URLInput.classify`, so it behaves
  like the palette (address or search). Empty → nil.
- `fieldText(_:)`: the full address of the page, empty for none or `about:blank`.
- `opensPopup(_:)`: what a pop-up may load into a new window: http/https, or nothing yet
  (`window.open('')`, filled in by script).

The field shows the page's address and follows it while the field is not being edited.

### Menu and palette

- File → **New Private Window** ⇧⌘N, from anywhere (also while a little window or the welcome flow
  is in front). Palette: "New Private Window".
- While a private window is the app's main window: page commands act on its page
  (`AppState.frontController`), ⌘W closes it (not while a sheet is open on it), ⌘L focuses its
  address field, and the commands for the browser window's tabs, sidebar and splits are off, as
  for a little window. Commands that go somewhere in the browser window bring it forward.
- The inbox still belongs to the browser window (a private window is never its parent and never
  counts as "looking at a terminal").

## Testing

- Core: `PrivateWindowRulesTests` (destination, field text, pop-up rule).
- App (`PrivateWindowTests`, real `AppState`, off-screen windows that never become key, the little
  windows' fixture site): a page loads in a private window and leaves no tab, no history, no
  favicon, no change to `space.json`; its controller is not in the registry; its store is not
  persistent and is shared by a second window; the store is dropped after the last window closes
  and a new window gets another; a cookie set in a private window is not in a Space's store;
  `target="_blank"` opens a second private window sharing the store; `window.close()` closes it;
  the menu's front page is the private window's; the address field loads typed text.

## Documents

`CLAUDE.md` (scope change line, architecture, a "Private windows" paragraph), `IDEAS.md` (what was
left out goes under "New, not yet decided").
