# Child terminals under a terminal tab: design

Status: draft, waiting for the owner's approval. Nothing is built.

## Why

The owner moved all terminal work into Singularity, with "Run terminals through herdr-core"
switched on. `herdr-bot` (the owner's Bot launcher, `~/.config/herdr-core/bin/herdr-bot`) already
runs in a Singularity terminal tab. What is lost compared with the Herdr app is sight of what the
Bot started: its workers, topic sessions and mailboxes are herdr-core terminals with no tab, and
Singularity shows only terminals it started itself. The owner cannot open a worker, watch it or
type into it without going back to the Herdr app.

The owner's words: "I want to see the sub-tabs."

## What it is

Under a terminal tab's row, the sidebar lists the herdr-core terminals that descend from that
tab's terminal, live. A click on such a row shows that terminal, as a real terminal the owner can
type into.

```
▾ ›_ Bender                    ● working
       plat135                 ● working
       plat77-review           ◐ needs you
       teema-nortal            ○ idle
  ›_ zsh
```

This is for any herdr-core child, not only a Bot's: `hc run --bg --name astro-dev …` typed in a
tab gives that tab a child row too.

## Scope decision this needs

`docs/superpowers/specs/2026-11-11-herdr-core-terminal-design.md` lists as a non-goal "Showing
herdr terminals that Singularity didn't start". This design reverses that, for descendants of a
tab's own terminal only. `CLAUDE.md`'s "agent orchestration (Herdr already does that; we only host
terminals)" still holds: Singularity starts, assigns, ends and restarts nothing here. It lists and
attaches. Approving this document is that scope change; `CLAUDE.md` gets a "Scope change" line.

## Goals

1. A terminal tab that runs through herdr-core shows its live descendants as rows under it, within
   about a second of their start, and drops them when they end.
2. A child row shows a name and a state mark (working, needs you, done, idle, none).
3. Clicking a child row shows that terminal in the tab's pane: full screen, keyboard, resize.
   Clicking the tab's own row shows the tab's terminal again.
4. Nothing about child rows is stored. After a restart of the app the rows are rebuilt from
   herdr-core.
5. With herdr-core off, not installed, or misbehaving, nothing changes: no rows, no errors shown.

## Non-goals (this part)

- The Bots panel (profiles with Start, board, history, topics list, mailbox counts).
- Recovery (`herdr-bot <id> --recovered` typed when a terminal lost its Bot).
- `[auto: …]` triggers (morning review, pilot).
- A replacement for `herdr-app do agent.focus`.
- Ending, restarting or starting a child from Singularity. No "End" in a menu: the owner types in
  the terminal, or the Bot does it.
- Child rows as tabs: no split of their own, no drag, no pin, no folder, no ⌘1…9, no palette entry.
- Inbox entries, banners or rail counts for a child. The row's mark is all there is (see Open
  points).
- Agent tools. No outside agent and no plugin (the Assistant's `terminals` tools included) sees,
  reads or writes a child terminal. Their lists and answers do not change.
- Terminals on other machines (`machine/t7`), and herdr terminals that descend from no tab.

## Anti-goals

- A child's shell or program ending because of something Singularity did (closing the view,
  switching rows, quitting the app). Only closing the *tab* acts on herdr-core, exactly as today.
- Rows that stay after their terminal is gone, or `space.json` being rewritten as workers come and
  go.
- Any new way to put text into a terminal without the owner's own keyboard.

## Approaches considered

1. **The app shows child rows itself (chosen by the owner, 2026-11-16).** Live rows from
   herdr-core's own facts, a real attached terminal on click. Costs app code in the sidebar, the
   terminal registry and one listener process.
2. **A plugin with a panel.** `hc ls` as a tree in the right-hand panel, `hc read` as a text
   picture of a screen, `hc send` to write. No app change, but not tabs and not a real terminal,
   the panel is shared with the Assistant, and `hc send` from a plugin would be a second way to
   type into terminals.
3. **A plugin that may open terminal tabs.** The same result as 1 through a new plugin power that
   today's rules deliberately don't give. Rejected.
4. **Children as stored tabs.** Rejected: they would outlive their workers and rewrite
   `space.json` constantly.

## How it works

### Facts from herdr-core

`hc events --json` (checked against hc 0.1.20) prints one JSON line with every terminal
(`{"seq":…, "terminals":[…]}`), then a line per change. Each terminal has `address` (`t64`),
`name` (may be null), `parent` (an address or null), `state` (`live`, …), `status.state`
(`working`, `blocked`, `done`, `idle`, `error`, or no status), `labels`, `foreground.argv`,
`title`.

- One `hc events --json` process for the whole app (`HerdrWatcher`, app target). It runs while
  Settings → Terminal has herdr-core on, `HerdrCore.locate()` finds `hc`, and any Space has a
  terminal tab: from launch, not from the first session (sessions are lazy, and rows must be back
  after a restart even with a web tab in front). A row can so appear under, and be clicked on, a
  tab whose own session doesn't exist yet; the tab's own session is then made as usual when its
  own terminal is first shown. Its output is read line by line; each line is handed to Core.
- If the process ends, it is started again after 2 s, then 4, 8, up to 60 s; a line that parses
  resets the wait. While it is down the rows stay as last known for 10 s, then all child rows are
  removed (stale rows are worse than none). The app quitting ends it.
- The builder checks the format of the change lines against the installed `hc` first (`hc schema`
  describes the API) and writes what was found into this document's "As built". If change lines
  can't be folded into a full picture reliably, the fallback is to end the
  process and start it again for a fresh first line, at most once a second. (`hc ls --json` is too
  thin for this: no `labels`, no `created_ms`.)
- Everything read is checked, as `HerdrCore.parseGet` does today. A line that doesn't parse is
  skipped and logged without its content.

### The tree (Core, pure, tested)

`Sources/SingularityCore/Terminal/HerdrTree.swift`: text lines in, a picture out.

- A tab's root is the live terminal whose `name` is `HerdrCore.terminalName(tabID:)`.
- Its rows are its live descendants (children, their children, …), in creation order
  (`created_ms`, then address). A terminal already reachable from one tab is never listed under
  another. A cycle or a parent that doesn't exist ends the walk there.
- **Mailboxes are passed through.** A terminal labelled `role=postkast` or `role=topic-postkast`
  is not a row; its children take its place (they are the Bot's or the topic's workers, parked
  under a mailbox only so reports don't land on the owner's input line). This is the one place the
  app knows a `herdr-bot` label. *(My call; see Open points.)*
- Depth: rows are indented by their level, at most 3 levels drawn; deeper ones are drawn at
  level 3.
- At most 30 rows per tab; beyond that one last line says "and N more".
- A row's name: `name`; without one, the last path part of `foreground.argv[0]`; else the address.
  Cleaned with `InboxText.clean`, cut to 60 characters. It is untrusted (any program names its
  terminal) and is drawn with `Text(verbatim:)`.
- A row's mark from `status.state`: `working` → working, `blocked` → needs you, `error` → error,
  `done` → done, `idle` → idle, anything else or none → no mark.

### The sidebar

- Child rows sit directly under their tab's row, inside the same section or folder, indented.
  They are not `SidebarItem`s and not `BrowserTab`s: `TabRow` (and a split's chip row) is followed
  by a `ForEach` over `state.herdr.children(of: tab.id)`.
- A tab with children gets a disclosure triangle; open by default; the collapsed set is kept in
  memory only. Collapsed, the tab's row carries one mark when any child needs you.
- A child row: mark, name, and on hover nothing more (no close button: there is nothing to close).
  Its tooltip is the terminal's address and folder. Context menu: "Copy Address" (`t64`) only.
- The row of the child being shown is highlighted instead of its tab's row.
- A tab inside a split: the children hang under the split's row, each drawn once, with their
  owner's chip not repeated. *(Builder's choice of exact look.)*

### Showing a child

- `AppState.shownChild: [UUID: String]` (tab id → child address), in memory. Clicking a child row
  selects its tab (as `selectTab` does) and sets the entry; clicking the tab's own row, or the
  child ending, clears it.
- The tab's pane then hosts the child's view instead of the tab's own: `PaneView` asks
  `terminals.childSession(address:under:)` when `shownChild[tab.id]` is set. The tab's own session
  is untouched and keeps running; only which view the pane hosts changes. `HostedView`'s
  newest-container rule already keeps one view in one place.
- A child's session (`HerdrChildSession`, or `TerminalSession` with an "attach only" mode: the
  builder's choice, whichever leaves `TerminalSession` easier to read) is a SwiftTerm view running
  `hc attach <address> --history 2000`. It:
  - never runs `hc run`, `hc kill` or `hc rm`;
  - has no launcher command, no project, no title or directory polling into a `BrowserTab`;
  - sends no inbox signals and is no `TerminalHandle` for any agent tool;
  - on `hc attach` ending while the terminal is still live (detach key, core restart) prints the
    existing "Detached … Press Return to show it again" line, and Return attaches again; when the
    terminal is gone, the pane goes back to the tab's own terminal.
- Sessions are made lazily on first click and kept (so switching back is instant) until the child
  leaves the tree, the tab closes, or the app quits; then the view's `hc attach` is ended, nothing
  else.
- A thin strip at the top of the pane names what is shown: `‹ Bender  /  plat135` with the first
  part a button back to the tab's own terminal. Without it the owner could type into a worker
  believing it is the Bot. *(My call.)*
- `hc attach` resizes the terminal to the viewer. If the Herdr app shows the same terminal at the
  same time the two sizes compete; that is herdr-core's behaviour and is left alone.

### What else it touches

- **Closing the tab** does what it does today: `hc kill` and `hc rm` on the tab's own terminal.
  Whether children end with it is herdr-core's rule (`die_with_parent`, `--outlive-parent`), not
  ours; by default they do end. So **a tab with live children always asks before it closes**, also
  with its shell at the prompt (`hc run --bg … astro-dev` returns to the prompt): "Close this
  terminal? It has N terminals under it. Most end with it." with Close and Cancel, in place of the
  "a program is running" alert when both apply. Typing `exit` in the shell cannot ask (the shell
  is already gone) and closes as today. *(My call.)*
- **Children that outlive their tab** (`herdr-bot` starts topics and mailboxes with
  `--outlive-parent`) then descend from no tab and are shown nowhere in Singularity. They are
  still in `hc ls` and the Herdr app. Accepted for this part.
- **The inbox and the tab's own terminal.** While a tab's pane shows a child, the tab's own
  terminal is not on screen. So: `isTabOnScreen` (and with it "looked at") is true for a terminal
  tab only while its own terminal is the one shown, so a question from the Bot behind a worker
  makes an entry and a banner as for any hidden tab; clicking a child row or typing in a child is
  not "going to" the tab (no `wentToTerminal`, entries stay, held questions stay held); "Go to
  terminal" and "Show Tab" on a card clear `shownChild` for that tab, so the tab's own terminal is
  what appears. The inbox's rules in Core don't change, only the facts fed to them.
- **⌘W** while a child is shown closes nothing of the child: it goes back to the tab's own
  terminal. A second ⌘W closes the tab as today.
- **The welcome flow, little windows, plugin tabs:** untouched.
- **Settings → Terminal:** no new switch. The rows exist whenever herdr-core terminals are on.
- **Test copies:** a copy with `SINGULARITY_HOME` set runs the watcher only when `HC_SESSION` is
  set too, so a trial never lists the owner's real terminals. Tests never run `hc`: Core takes
  text, and the app's watcher takes a line source that tests feed by hand.

## Tests

- Core `HerdrTreeTests`: roots by name, descendants and order, mailboxes passed through, a topic's
  workers, depth cap, the 30-row cap, a cycle, a missing parent, a terminal claimed by one tab
  only, names cleaned and cut, marks, a change line folded in, a line that doesn't parse.
- App: rows appear and go as lines are fed; clicking sets `shownChild` and the pane hosts the
  child's view (a fake session, no shell, no `hc`); the child ending returns the pane; ⌘W; the
  collapsed mark; nothing written to `space.json` (the Space is not marked dirty); no agent tool's
  list changes; no window is made key.
- By hand, by the owner, in the daily copy after release: a Bot with workers and a topic, a click
  on a worker, typing, going back, a worker ending while shown.

## Left to the builder

File and type names beyond those given; the exact look of indent, marks and the strip (in the
sidebar's existing style, marks reusing the inbox's symbols where one fits); whether the child
session is its own small class or a mode of `TerminalSession`; the fallback to `hc ls` if change
lines prove awkward.

## Open points for the owner

(Also marked "My call" above: the name strip over a shown child, and asking before closing a tab
with live children.)

1. **Mailboxes hidden** (`postkast-<id>`, `kast-<slug>`), their workers lifted under the Bot or
   topic. The alternative is the plain tree as herdr-core has it, with workers under a mailbox
   row. Hidden is what the Herdr Bots panel did.
2. **A child shows in its tab's pane**, replacing the tab's own terminal while shown, so Bot and
   worker are not side by side. Side by side would mean child rows that can be dragged into
   splits, which is a good deal more.
3. **No inbox entry for a child that needs you**, only the mark on its row and on a collapsed tab.
   A Bot is told by hc when a worker is blocked and tells the owner itself.
