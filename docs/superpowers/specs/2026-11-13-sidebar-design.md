# Sidebar: launchers, Space icons, hide and resize, agent activity moves out: design

Date: 2026-11-13. Status: approved by the owner and built the same day. "As built" at the end
overrides the design where they differ.

## Why

The owner looked at the bottom of the sidebar and asked for five changes, in their words:

- "lets move agent activity to settings or somewhere else, i belive noone is going to check this anyway"
- "lets aling new tab button to the left. it should span until the edge"
- "it would be neat if it was possible to open claude code or similar agent from there": "i press on
  claude logo and claude code opens in a terminal"; "i want to add my own commands too, so it would
  be neat if it was configurable"
- "id like to be able to assign icons/emojist to spaces as well"
- "the should be a way to minimize/toggle the sidebar and maybe change its width"; hidden, it should
  come out at the left edge "like in arc"

None of these is a tab type. The owner asked for them directly, so this document is the scope
change; `CLAUDE.md` gets a line for it when it is built (see "Documents").

Everything below marked **(my call)** was decided by the writer, not said by the owner.

## What success looks like

1. The bottom of the sidebar is one row from the window's left edge to the sidebar's right edge:
   "+ New Tab" on the left, then small buttons on the right: New Terminal, the Claude logo, the
   Codex logo. No "Agent activity" section above it.
2. The owner clicks the Claude logo. A new terminal tab opens exactly where and how New Terminal
   would open one, and `claude` starts in it. When Claude Code exits, the shell prompt is there.
3. In Settings → Terminal the owner adds a launcher "Claude (yolo)" with the command
   `claude --dangerously-skip-permissions` and an emoji; its button appears in the row at once.
4. In Edit Space the owner gives "Music" the emoji 🎧; the Space's circle in the rail shows 🎧
   instead of "M".
5. The owner drags the sidebar's right edge; it gets wider, and is that wide after a restart.
6. The owner presses ⌘S. The sidebar is gone and the page has the whole window. Moving the pointer
   to the window's left edge slides the sidebar out over the page; moving away slides it back.
   ⌘S again brings it back for good.
7. Settings → Agents has, per Space, a way to see the agent activity that used to be in the sidebar.

## Non-goals

- Launchers in splits ("New Terminal" in a split stays a plain terminal), per-Space launcher lists,
  keyboard shortcuts per launcher, detecting whether a launcher's program is installed.
- Launchers do not start, assign, watch or restart anything: a launcher types one command into a
  new terminal. Agent orchestration stays out of scope.
- No way for an agent tool, a page, an artifact or a plugin to add, change or run a launcher.
- Space icons from a symbol library or image files; the emoji anywhere other than the rail
  (menus, palette, little windows keep the plain name) **(my call)**.
- Reading Arc's Space icons in the Arc import. Goes to `IDEAS.md` under "New, not yet decided".
- A per-Space sidebar width; sidebar on the right; a setting to turn the slide-out off.
- A mark for waiting inbox entries while the sidebar is hidden (see "Known limits").

## Anti-goals

- A launcher's command running again by itself: after a restart, after "Press Return to start a
  new shell", or when a herdr-core tab finds its shell again. It runs once, when the tab is made.
- The hidden sidebar's edge strip taking clicks, scrolls or drops meant for the page.
- The slide-out closing under the owner's hand: while a menu opened from it is showing, while a
  tab dragged out of it is still in the air, while the inbox panel opened from its tray button is
  open.
- ⌘S or the slide-out acting on the hidden sidebar while the welcome flow covers the window, or
  while a little window is in front.

## 1. The bottom row

Today (`SidebarView.swift`) the row `NewTabButton` + `NewTerminalButton` sits in the column to the
right of the 48-pt Space rail. It moves out of that column, below both the rail and the column, so
it spans the sidebar's full width. The rail and the tab list end above it.

- "+ New Tab" fills the row; its "+" is centred under the rail's circles (x = 24) **(my call)**, the
  label follows. The whole stretch up to the first right-hand button is clickable.
- On the right: New Terminal (as today), then the launchers in their Settings order. At most four
  launcher buttons are shown; when there are more, the rest are in a small "more" menu at the end
  of the row **(my call)**. Each button has a tooltip with the launcher's name.
- The Downloads pane stays where it is, in the column.

## 2. Launchers

**Model (Core, tested).** `Launcher`: `id` (UUID), `name`, `command`, `icon`. `icon` is one of
`"claude"`, `"codex"` (the two bundled logos), one emoji, or empty. Empty shows the first letter of
the name **(my call)**. The list is `AppSettings.launchers` in `~/Singularity/settings.json`,
decoded tolerantly like the other settings:

- key absent → the defaults: Claude Code (`claude`, Claude logo) and Codex (`codex`, Codex logo);
- an empty list stays empty (the owner removed them all);
- an entry without a command, or with an unknown shape, is dropped; a command is one line
  (line breaks are removed when saving).

Both defaults are always pre-filled, also on a Mac without the program **(my call)**: no check
through the login shell at launch; a missing program says "command not found" in the terminal, and
the owner removes the row.

**Starting one.** `AppState.openTerminal(launcher:)` goes through the same code as New Terminal
(`newTerminal(inFolder:alwaysAsk:)`): same folder, same project rules, and when the Space has
projects and the folder has none, the same picker. The picker's mode carries the launcher so the
choice then starts it (`PaletteMode.newTerminalIn` gets the launcher's id). It closes the welcome
flow like `openTerminal` does.

**Running the command.** The command is typed into the new tab's shell, followed by Return, as if
the owner had typed it **(my call, for these reasons)**: the tab's login shell has the owner's
PATH, nvm, aliases and shell functions (`claude` can be a shell function); the shell is still there
when the program exits; and the same route works for herdr-core terminals. Requirements for the
builder:

- The command is handed to the terminal session when the tab is created and kept only in memory.
  It is never written to `space.json`. A restored tab, a restarted shell and a re-attached
  herdr-core shell get nothing typed.
- It must arrive whole with the owner's real shell start-up (zsh with a slow `.zshrc`). If typing
  it right after the shell starts proves unreliable, wait for the shell's first output. The builder
  chooses, and checks both the built-in terminal and herdr-core.
- If herdr-core falls back to the built-in terminal, the command is still typed, once.

**Settings → Terminal → "Launchers".** A list: icon, name, command; add, remove, drag to reorder.
The icon control offers the Claude logo, the Codex logo, or an emoji (the same emoji control as in
Edit Space). Changes go through `AppState.updateSettings`.

**Palette.** One command per launcher: "New <name> Terminal" **(my call)**.

**Logos.** Two small single-colour template images in `Resources/` (tinted like the other sidebar
icons). They are other companies' marks, used only to name their programs **(my call)**; the
alternative is letters or emoji.

## 3. Space icons

- `Space.icon: String?` in `space.json` (absent in old files → nil; decoded tolerantly). A Core
  function keeps it to one emoji: the first grapheme of what was typed, only if it is an emoji,
  else nil. Tested.
- `SpaceFields` (shared by Edit Space and the welcome flow's step 2) gets an "Icon" row in both
  styles **(my call: both, since the fields are shared)**: a one-character field, a button that
  opens the macOS emoji picker for it, and a way to clear it.
- `SpaceDot` in the rail: the emoji in place of the letter, on the Space's coloured circle; no
  icon → the letter, as today. The inbox count badge and the selection ring do not change.
- The slug, tool names and folder do not depend on the icon.

## 4. Sidebar width

- `AppSettings.sidebarWidth` (default 270, kept between 220 and 480 **(my call)**; a Core function
  clamps, tested). One width for all Spaces. `MainView` uses it in place of the fixed 270.
- A thin strip along the sidebar's right edge, with the left-right resize cursor, drags the width.
  The setting is written when the drag ends, not on every move. Double-click resets to 270
  **(my call)**.
- The strip's top end lies in the window's invisible title-bar strip, where macOS starts a window
  drag before asking the view. `PaneDragHandleView` solved this by switching `window.isMovable` off
  while hovered; do the same, and no SwiftUI `.help()` there.
- The window's minimum width (820) stays; at 480 the page still has 340.

## 5. Hiding the sidebar, and the slide-out

**The switch.** `AppSettings.sidebarHidden` (default false, remembered across launches
**(my call)**). View → "Hide Sidebar" / "Show Sidebar", ⌘S, and the same command in the palette.
⌘S is free: the Save item is already replaced by Close Tab. The command is disabled while the
welcome flow covers the window or a little window is in front, like the other sidebar commands.

**Hidden.** The content area has the whole window, with its usual 8-pt margin on all four sides.
The three window buttons (close, minimise, zoom) are hidden with the sidebar and come back with
the slide-out, as in Arc **(my call)**; otherwise they would sit on top of the page's corner.

**Slide-out.** While hidden, the pointer reaching the window's left edge slides the sidebar out
over the page: the same sidebar at the same width, with its own background (the sidebar material
and the Space tint), a shadow on its right edge, and the window buttons. It slides back shortly
after the pointer leaves it (about 0.3 s **(my call)**), with a short animation; no animation under
Reduce Motion. Rules, as a pure Core function with tests (inputs: hidden, pointer at edge, pointer
inside, menu open, tab drag under way, inbox panel open from the tray):

- it opens only when the sidebar is hidden, the main window is key and nothing covers it (welcome
  flow, sheet);
- it stays while the pointer is inside it, while a context menu or pull-down opened from it is
  showing, while a tab drag that started in it is under way (the drag's source view must not
  disappear mid-drag), and while the inbox panel opened from its tray button is open;
- a drag does not open it **(my call)**: a pane dragged to the window's left edge while the
  sidebar is hidden does nothing, see "Known limits";
- choosing a tab does not close it; leaving does.

**The edge.** The trigger is a thin AppKit view with a tracking area in the 8-pt margin left of
the content, so it never lies over the web page or terminal and takes no clicks, scrolls or drops.
With the window at the screen's left edge or in full screen the pointer stops at x = 0, which is
inside that margin.

**One sidebar.** The slide-out is the same `SidebarView`, not a second copy with its own scroll
position and open folders. How it is laid out (overlay with an offset, or otherwise) is the
builder's choice.

**Inbox while hidden.** ⌃⌘I, the palette's Show Inbox, and an approval arriving while the app is
active still open the inbox panel. With no tray button on screen, the panel sits at the window's
top-left corner, where the tray button would be **(my call)**. It does not pull the sidebar out.

**Resize while slid out.** The width strip works on the slide-out too **(my call)**.

## 6. Agent activity

- `AgentLogPane` leaves `SidebarView`. Nothing else about the log changes: every call is still
  appended to `<space>/agent-log.jsonl`, tabs opened by agents keep the sparkles badge, tabs being
  worked on still pulse.
- Settings → Agents → "Spaces": each Space's row gets an "Activity…" button **(my call)** that
  opens a sheet with that Space's recent entries (the last 40, newest first, the same rows as
  today, updating live). Rows are not clickable there **(my call)**: Settings is another window.
- The policy text the pane's header showed ("Ask before acting") is already in that row's policy
  control.
- Clearing the log stays in Settings → Data & privacy.

## Known limits

- With the sidebar hidden and the app in front, an agent that finishes or waits (a level-1 inbox
  entry) shows nothing in the window until the sidebar is slid out: the counts live on the rail.
  Approvals and held questions still open the panel; in the background, banners and the Dock badge
  work as before. A mark for this is left out on purpose.
- With the sidebar hidden, a pane cannot be dragged into Pinned, a folder or Tabs: a drag does not
  bring the sidebar out (a tracking area gets no events during a drag; the edge would have to
  become a drop target). Press ⌘S first. Tabs dragged *out of* the slide-out onto panes work.
- Launchers trust `settings.json`: whoever can write that file can make a button run anything.
  That file is already the owner's alone, and only the owner's click runs a launcher.

## Left to the builder

- How the command reaches the shell reliably (see section 2), and where the pending command lives
  between tab creation and shell start.
- The layout mechanics of the slide-out and its animation; the exact strip widths and delays.
- The emoji control (a field plus `orderFrontCharacterPalette`, or otherwise), as long as it
  stores one emoji and can be cleared.
- Drawing or sourcing the two logo images as template images.
- The order of work. The five parts are independent; suggested: bottom row and activity move,
  Space icons, launchers, width, hide and slide-out.

## Tests

- Core (Swift Testing): `Launcher` decoding (absent key, empty list, broken entries, line breaks),
  the one-emoji rule, the width clamp, the slide-out rules, `PaletteMode`/project-picker path with
  a launcher (the Space rules already have tests; add the launcher cases).
- App tests (off-screen, never key, `TestAppState`): a launcher makes a terminal tab in the right
  folder and project and hands the session its command once; a restored tab has none; the rail
  shows the emoji; the hidden state lays out the content full width; the activity sheet lists
  entries. No test types into a real shell that runs `claude` or `codex`: use a harmless command
  (`echo`) and a temp home.
- By the owner's hands: the slide-out's feel, dragging the width, the emoji picker, a launcher with
  the real `claude`.

## Documents

When built: `CLAUDE.md` gets a scope-change line (owner decision, 2026-11-13), a short "Sidebar"
entry under Key decisions with the things that bit us, the new files in the architecture list, and
its Approvals paragraph stops saying the log is "shown in the sidebar's Agent activity pane".
`IDEAS.md` gets "Arc's Space icons in the Arc import" under "New, not yet decided". This document
gets an "As built" section.

## As built (2026-11-13)

- **Launcher command:** typed into the shell after `TerminalSession.waitUntilReady` (the shell's
  first output, at most 5 s), from `didStartProcess`, which both engines and herdr-core's fallback
  go through. Checked against the owner's real login shell by the opt-in test
  (`SG_REAL_SHELL=1 swift test --filter SidebarStateTests/aRealShell`): typed once, and a second
  shell gets nothing. Not tried with herdr-core switched on.
- **Launcher icons in Settings:** the icon menu offers the two logos, ten suggested emoji and
  "first letter". There is no free emoji picker in that row; any emoji can be set by editing
  `settings.json`. Edit Space has the full picker.
- **Settings holds launcher rows as typed**, so a new row with an empty command stays in the
  list while it is being filled in; only rows with a command become buttons.
- **Slide-out closing:** a 0.15 s timer that reads the pointer, not mouse-exited events (they are
  not delivered while a menu or drag has the mouse). "A tab drag under way" is read as "a mouse
  button is down".
- **The slide-out, dragging the width and the emoji picker were not tried by hand**: tests cover
  the rules and off-screen pictures cover the layout (shown, hidden, slid out), but no test moves
  a pointer. These are the owner's to try first.
- **Window buttons** are hidden through `standardWindowButton(_:)?.isHidden`; not checked across
  entering and leaving full screen.
