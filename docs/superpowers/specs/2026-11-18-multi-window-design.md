# More than one browser window: design

Date: 2026-11-18. Status: design, waiting for the owner's approval of this document. Asked for by the owner
("hakkame seda arendama", after "I'll certainly need several windows"). Decisions marked
**owner** were made by the owner in the conversation; everything marked **builder's call** was
proposed by the builder and accepted by the owner in one go ("sobib"), and may be revisited.

## Why

The owner gives demos in meetings and shares one window in Google Meet. The shared window must
show the Space's pages *logged in* (a private window has no logins), with the sidebar hidden and
nothing else of the owner's screen, while the rest of the browser (Meet itself, notes, terminals)
stays in another window on the owner's own screen. Demos usually involve several sites, so the
shared window needs tabs (**owner**: a single detached page, i.e. a little window, is not enough).

## What success looks like

1. The owner is in the "work" Space in the window they always use, with Meet open in a tab.
2. File → New Window (or the palette) opens a second, full browser window on the same Space.
3. In the second window the owner hides the sidebar (⌘S), opens the demo's tabs and shares that
   window in Meet. The first window still shows its sidebar and the Meet tab.
4. Both windows show the same tab list for "work" (**owner**: the same Space may be open in two
   windows, as in Arc). Each window shows its own selected tab.
5. Clicking in window 1 a tab that window 2 is showing brings it to window 1; window 2 then shows
   another tab (**owner**).
6. Quitting and starting again brings both windows back, each with its Space, selected tab,
   sidebar shown/hidden, size and position.

## Goals

- Any number of browser windows, all equal: there is no "main" and "secondary" window.
- Each window has its own selected Space, its own selected tab per Space, its own sidebar
  shown/hidden state and its own frame.
- A tab (and with it a whole split) is on screen in at most one window.
- Commands act on the front browser window.
- Windows are restored at launch from `~/Singularity/state.json`.

## Non-goals (this round)

- Dragging a tab from one window to another (**builder's call**; goes to `IDEAS.md`). Within the
  same Space a click brings the tab over; into another Space, the existing "move to Space" paths.
- Windows that hold tabs of their own, outside any Space. Tabs belong to Spaces, never to windows.
- Changes to little windows or private windows beyond pointing "the main window" at "the front
  browser window".
- A per-window sidebar width (**builder's call**: one width for all windows, `AppSettings.sidebarWidth`).

## Anti-goals (would make it a failure even if it works)

- One tab's web view or terminal view shown in two windows, or flickering between them
  (`HostedView`'s newest-container rule must never be what decides; the model must).
- Closing a window closing tabs, or losing a Space's tab list.
- Any regression for the owner who uses one window: with one window everything behaves as today,
  and `state.json` from 0.17.0 loads into exactly one window as before.
- The inbox or approvals reaching a window the owner isn't looking at so that Return typed in a
  terminal could press a button (the inbox panel stays non-activating, as today).

## Constraints

- macOS 14+, SwiftUI with AppKit where needed (CLAUDE.md). No new dependency.
- `AppState` stays the single source of truth for the model (Spaces, tabs, splits, settings).
- `space.json` stays per-machine state of the Space; window layout lives in `state.json`.
- Every existing rule in CLAUDE.md that says "the main window" must be re-read as "the front
  browser window" or "every browser window", decided case by case below.

## Approaches

- **A. SwiftUI `WindowGroup`, all windows equal.** (**owner's pick**.) `Window("Singularity",
  id: "main")` becomes `WindowGroup(id: "browser", for: UUID.self)`, the value being the window's
  id. Commands find the front window through `focusedSceneValue`/AppState's own key-window
  tracking. Pros: all windows the same, New Window and the Window menu come almost free, stays in
  SwiftUI. Risk: SwiftUI restores windows by itself and macOS 14 has no public switch to turn
  that off; we turn it off at the `NSWindow` level (`isRestorable = false`) and reopen windows
  from `state.json` ourselves.
- B. Main window stays a SwiftUI `Window`, extra windows are AppKit (`NSWindow` +
  `NSHostingView`, like little and private windows). Full control, but two kinds of browser
  window, and every rule would have to say which one (what if the main one is closed and a second
  stays?). Rejected: the owner's use needs two equal windows.
- C. All browser windows made by AppKit, SwiftUI only as content. Equal windows, full control,
  but the largest rewrite (menu commands, `hiddenTitleBar`, scene plumbing all by hand). Rejected
  as more work than A for the same result.

## The model

### `BrowserWindow` (new, Core, pure, tested)

```
struct BrowserWindowState: Codable, Identifiable {
    var id: UUID
    var spaceID: UUID?                     // the Space this window shows
    var selectedTabIDs: [UUID: UUID]       // Space id → selected tab in this window
    var sidebarHidden: Bool
    var frame: CGRect?                     // screen coordinates; nil = let macOS place it
}
```

`AppStateFile` gains `windows: [BrowserWindowState]` and `frontWindowID`. Decoding an older file
(no `windows`) makes one window from `selectedSpaceID`, each Space's `selectedTabID` and
`AppSettings.sidebarHidden`. `selectedSpaceID` and `AppSettings.sidebarHidden` keep being written
(the front window's values) so a downgrade to 0.17.0 opens sensibly (**builder's call**).

`Space.selectedTabID` stays and means "the tab last selected in this Space in any window". It is
what a window shows the first time it shows that Space (New Window, switching Space), and what
the existing rules that pick a neighbour after a close keep working on.

### The one-place rule (Core, pure, tested)

`WindowLayout` (name is the builder's) holds the open windows and answers:

- **Which tabs a window shows**: its selected tab in its Space, or that tab's whole split.
- **Select tab T in window W**: W's selection becomes T. Every *other* window showing T (or a tab
  of T's split) gets a new selection: the neighbour that the existing close rule
  (`Space.removeTab`'s neighbour logic) would pick, skipping tabs on screen in any other window;
  if none is left, nothing (the empty-Space placeholder). (**owner**: the tab comes to the window
  the owner clicked in.)
- **A tab closed**: every window that showed it picks a neighbour the same way.
- **A Space deleted**: every window showing it moves to the Space the existing rule picks
  (`spaces.first`); if there are no Spaces left, the existing placeholder behaviour.
- **A split created/removed**: windows showing a member re-checked so no two windows show members
  of the same split.

The same rule covers web, terminal, artifact, note, home and plugin tabs: anything shown in a
pane.

## Behaviour (all **builder's call**, accepted by the owner)

- **New Window**: File → New Window and the palette open a window on the *front* window's Space,
  showing that Space's last-selected tab if no other window shows it, else the empty-Space
  placeholder. Shortcut ⌘N (see below).
- **Sidebar hidden is per window** (⌘S acts on the front window). Peeking (the slide-out) is per
  window too. The sidebar width is shared.
- **Commands act on the front browser window**: ⌘T, New Terminal (and its project picker), the
  palette, ⌘W (closes the tab in the front window), ⌘1…⌘9 and every Space switch, Find, Reload,
  Zoom, Print, split commands, New Folder, the launchers. `inMainWindow { … }` becomes "in the
  front browser window, opening one if none is open".
- **Closing a window** (**builder's call**): File → Close Window, ⇧⌘W (free today), and ⌘W in a
  window that shows no tab (the empty-Space placeholder), as in other browsers; needed because a
  window with its sidebar hidden also hides its close button. While the welcome flow covers a
  window, ⇧⌘W closes the flow first, as ⌘W does today. Closing a window closes no tab. Its entry leaves `state.json`. Closing the last browser
  window keeps today's behaviour (the app quits).
- **Agents**: tabs opened by agents still go into their Space without being selected in any
  window. `list_tabs`'s `selected`/`visible` flags mean "selected/on screen in any window".
- **Inbox**: the panel opens beside the tray button of the front browser window (or that window's
  corner if its sidebar is hidden, as today). A terminal counts as "looked at" when it is on screen
  in the key window. Going to an entry (Go to terminal, Show Tab) selects it in the front window
  (bringing it over from another window by the one-place rule).
- **Assistant panel**: a plugin has one page view, so the panel is in one window at a time: ⌃⌘J
  and the sidebar button show it in the front window and take it away from any other. Its width
  stays shared. `frontTab` / `onFrontChange` report the front window's tab.
- **Little and private windows**: "Open in <Space>" lands in the front browser window (opening one
  if none). `showMainWindow` becomes "bring the front browser window forward, or open one".
- **Welcome flow**: covers the window it was opened in only (**builder's call**); other windows
  stay usable.
- **Restore at launch**: every window from `state.json`, with its Space, selections, sidebar
  state and frame; frames off every screen are dropped (macOS places the window).
- **Window title / Window menu**: each window's title is its Space's name (the menu lists them).

## Decided after the builder check (**owner**, 2026-11-18)

1. **Shortcut.** New Window takes ⌘N, as in other browsers. New Note moves to ⌃⌘N (free today);
   Today's Note stays ⌥⌘N, New Private Window ⇧⌘N. Menu, palette and the notes' docs follow.
2. **A tab the app selects without a click in a window** (a new artifact file opening by itself,
   `openArtifact`; an artifact page's `singularity.open`, `openInNewTab`; anything else that
   selects a tab on its own) goes to the window where its cause is on screen: the window showing
   the terminal or artifact page it came from. When the cause is on screen in no window, the tab
   is added to the sidebar and selected in no window (no window's selection changes). Actions the
   owner takes (Go to terminal / Show Tab on a card or banner, "Open in <Space>" in a little or
   private window, the palette, menus) go to the front browser window. So the window shared in a
   meeting never changes by itself. `WindowLayout`'s select call takes the origin window (or
   none) from the start, and its tests cover "no origin window".

## Left to the builder

- Names (`WindowLayout`, `BrowserWindowState`), file layout, how `AppState`'s ~60 uses of the
  selected Space are split between "front window" and "a given window".
- How the front window is tracked (`NSWindow` key/main notifications vs `focusedSceneValue`), as
  long as commands and the inbox agree on it.
- How SwiftUI's own window restoration is switched off on macOS 14.
- Tests: Core rules in Swift Testing; app tests with two windows off-screen, never key.
