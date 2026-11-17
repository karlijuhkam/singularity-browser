# Space home: a new tab opens as the Space's home

Date: 2026-11-17. Status: design, waiting for the owner's approval. Decisions marked **owner** were
made by the owner in the brainstorm; everything else is the designer's call and is open to change.

## Why

The owner works in a Space with many terminals (their own coding agents), pages, notes and
artifacts. Two moments have no good place today:

- **Starting work** in a Space: where was I, which project, what did I last write.
- **Coming back for clarity** while several agents run: which ones are working, which wait for
  me, which finished, and what changed since I last looked.

Today an empty Space shows only the orb, and ⌘T opens the command palette. There is no screen that
answers either question; the answers are spread over the rail counts, the inbox panel and the
sidebar rows.

## What it is

- **owner:** a new tab opens as the Space's **home** (⌘T, the sidebar's New Tab button). Type an
  address or a search there and the same tab becomes that page, like a browser's new tab page.
- **owner:** the home is both a launch pad and an overview of the work.
- **owner:** the home's one row can hand what the owner typed to the Assistant ("Ask Assistant"),
  whose panel then opens at the right and carries on there.
- **owner:** later, a "Summarise" button that asks the Assistant for a written overview of the
  Space. **Not part of this design**; it goes to `IDEAS.md` as a follow-up.
- **owner:** the content below (rows, sections) was shown as a sketch and accepted.
- **owner:** built natively in the app (approach 1 below).
- **owner:** the orb is on the home too.

```
┌ Home — Work ─────────────────────────────────────────────┐
│                          ( orb )                         │
│  [ address, search or question…                       ]  │
│    ↳ Open · Search Google · Ask Assistant                │
│                                                          │
│  WAITING FOR YOU (2)                                     │
│   ● claude · api-server   asks: "Which option?"   [Go]   │
│   ● Approval: an agent wants to submit a form     [Show] │
│                                                          │
│  TERMINALS                                               │
│   ◐ working  codex · web        12 min                   │
│   ✓ done     claude · api       5 min ago          (new) │
│   ○ idle     zsh · infra                                 │
│                                                          │
│  PROJECTS                     RECENT                     │
│   api-server  [+ terminal]     📝 Today's note           │
│   web         [+ terminal]     ◆ dashboard.html          │
│   infra       [+ terminal]     ◆ invoices (app)          │
└──────────────────────────────────────────────────────────┘
```

## Goals, non-goals, anti-goals

Goals:
- ⌘T always lands on the home of the selected Space, and from there anything starts in one or two
  keystrokes: an address, a search, a palette result, a question to the Assistant, a terminal in a
  project.
- One look tells what every terminal of the Space is doing and since when, and what waits for the
  owner.
- No AI in the app: the home shows facts the app already has. The Assistant only receives text the
  owner typed and chose to send to it.

Non-goals (this design):
- The "Summarise" button (later, separately).
- Browsing history on the home (history UI beyond the palette stays out of scope). "Recent" lists
  files (notes, artifacts, apps), not visited pages.
- Answering inbox cards on the home: the home links to them; answering stays in the inbox panel
  and under the plugin's page, where the 0.5 s lock and the no-default-button rules live.
- Customising the home (choosing, ordering or hiding sections), widgets, pictures, weather,
  calendar, email: none of it.
- A home for little windows; a home that agents can read.

Anti-goals (would be a failure even if it works):
- The home becoming slower than the palette for the owner's most common ⌘T use: type and Return.
- Home tabs piling up in the sidebar.
- Any new way for a page, plugin or agent to learn terminal states, inbox contents or file lists.
- Anything written to disk that the owner didn't ask for (the "new" marks live in memory only).

## Constraints

- `CLAUDE.md`'s scope rule: a home is a new tab kind, so it fits "if it is a tab type". It still
  gets a scope-change line in `CLAUDE.md`, like notes did.
- AI lives only in plugins. The app never calls a model; "Ask Assistant" passes text to a plugin
  through a new, declared permission, and the plugin decides what to do with it.
- Everything a terminal, agent or page reports is untrusted (titles, messages, questions):
  `InboxText.clean`, `Text(verbatim:)`, cut to the lengths the inbox already uses.
- Never make a window key in tests; no test starts a shell (terminals are `TerminalHandle` fakes);
  no test runs the real `claude`.

## Approaches

1. **A new tab kind `.home`, a native SwiftUI view (chosen, owner).** The view reads the app's own
   state (`InboxCenter.board`, the Core `Inbox`, `Space.projects`, launchers, `NoteFiles`,
   `ArtifactFiles`) directly. No new bridge, native look, fits the scope rule. Cost: the look is
   changed in Swift.
2. *A built-in HTML page served like an artifact, fed through a bridge.* Easier to restyle, but a
   page would need terminal states and inbox contents, a door no page has today. Rejected.
3. *A bundled plugin, like the Assistant.* Removable, but a plugin can't see the inbox, projects or
   file lists and sees terminals only with `terminals` and a per-Space switch; it would need several
   wide new permissions, and "one page, one place" clashes with a tab made fresh on every ⌘T.
   Rejected.

## Design

### The tab

- `TabKind.home` (no payload). Saved in `space.json` like any tab, so an open home survives a
  restart. Sidebar row: a house symbol and the title "Home"; it lives where new tabs land today
  (the selected tab's folder rules of New Tab apply unchanged).
- **One untouched home per Space.** ⌘T selects the Space's existing home tab if there is one,
  instead of making another (`HomeRules.reuse`, Core). A home tab is "untouched" by definition: the
  moment it becomes something else it is no longer a home.
- **Becoming something.** From the home's row: an address or search turns *the same tab* (same id)
  into `.web(url)` and loads it; the web view is created then (lazily, as today). Anything else that
  makes a new tab from the home (a note, an artifact, a new terminal, a launcher, a plugin's Open as
  Tab, any palette command) gets a **new** tab id as today; the rule (designer's call, `HomeRules`):
  if, when the action returns, a tab that didn't exist before it is selected in the home's Space, the
  home tab is removed and the new tab takes its place (same row in the sidebar, same pane in a split).
  No "replace" context is threaded through `newTerminal`, `openNote` and friends. A command that opens
  a picker (New Terminal in…) leaves the home until the picker makes the tab; cancelling it leaves the
  home as it was. So ⌘T → Return never leaves a stray home behind. Going to an *existing* tab (a terminal row, an inbox row, an already-open note)
  selects that tab and leaves the home where it is.
- Closing works as for any tab (⌘W).
- In a split: a home tab may be a pane. "Split with…" keeps using the palette as today.
- **Empty Space:** the content area shows the home view (no tab is made), with the orb on top (see
  The orb). Typing in this tab-less home makes a new tab as the palette does now.

### Keys and menus

- ⌘T and the sidebar's New Tab (button and right-click menu): open the home (above).
- ⌘K "Command Palette": unchanged, opens the palette over the page.
- ⌘L "Open Location…": unchanged; with no selected tab it opens the home instead of the palette.
- The home's row has the keyboard focus whenever the home is shown; Esc does nothing on the home
  (there's nowhere to dismiss to).
- While the welcome flow covers the window, ⌘T behaves as it does today (closes the flow first).

### The orb

- **owner:** the live orb sits at the top of the home, centred above the row (about 96 pt; the exact
  size is the builder's, checked with the owner in the visual pass). It is the same `OrbView` as the
  empty-Space placeholder today, with `stopsWhenIdle: true`, so every existing rule holds: it
  animates only while someone is looking (`OrbAnimation.shouldAnimate`), stops after 30 s without the
  pointer over it, holds its last frame, is one still frame under Reduce Motion, and falls back to the
  PNGs without Metal. Only the shown home has one (a home tab not on screen draws nothing).
- The empty Space's home has it in the same place, so the empty Space looks as it does now plus the
  row and sections.

### The row

- It is the palette's search, inline: the same matching (`FuzzyMatcher`, `URLInput`) and the same
  result rows, history matches included (open tabs, history, notes, commands, URL, search), shown
  under the field as the owner types, so ⌘T → type → Return lands where the palette's would. "No
  browsing history on the home" means no history *section*, not fewer search results.
  Shared code, not a copy: the palette's result logic is pulled out so both use it.
- **Ask Assistant** is the last row whenever the field isn't empty and a plugin that may receive
  asks is approved (below). Return picks the first row, as in the palette; ⌘Return picks Ask
  Assistant directly.
- Empty field: no result list; the sections below show.

### Sections (top to bottom)

All of this Space only. Each row is a button; long text is cut with an ellipsis.

1. **Waiting for you (n)**: the Space's inbox entries that the inbox counts (questions, permissions,
   approvals, waiting and done agents). Each: agent or source, terminal title, the entry's first
   line; buttons: **Go** (for a terminal: `showTab`, which already clears the entry as "went to")
   and **Show** for approvals (opens the inbox panel at that card, without the keyboard unless the
   owner clicked). No answer buttons. Hidden when empty.
2. **Terminals**: every terminal tab of the Space, from `TerminalBoard` (working / waiting / done /
   idle / unknown, and "since"), with program in front, the tab's title (untrusted) and project tag.
   Order: waiting, working, done, idle, unknown, then by "since". Click selects the tab. A **(new)**
   mark when the row's state changed after the owner last left this Space's home; that time is kept
   per Space in memory only (lost on quit). Hidden when the Space has no terminals.
3. **Projects**: `Space.projects`, each with **+ terminal** (New Terminal in that project, replacing
   the home tab) and a menu of the launchers (`AppState.launchers`) for that project. When the Space
   has no projects: one line "Add a project…" that opens Edit Space.
4. **Recent**: up to 8 files changed most recently: the Space's notes (`NoteFiles.list`) and artifact
   pages and apps (`ArtifactFiles.listPages`, apps marked), by modification date. Click opens
   (or selects the open tab). Read off the main actor; refreshed when the home appears and when the
   artifact watcher or a note save reports a change. Hidden when empty.

Times are relative ("12 min", "5 min ago") and tick once a minute while the home is on screen.

### Ask Assistant

- New plugin permission **`ask`** (a widening, so the plugin pauses until re-approved; the approval
  sheet says "Receives what you type into a new tab's Ask row"). Needs a `panel` (refused otherwise:
  "it asks to receive questions but has no panel").
- **owner:** Ask works in every Space, but the Space is named only where the plugin may know it.
  In a Space switched on for the plugin (`PluginApproval.enabledSpaces`, the same test as `front`'s),
  the message carries `space: {slug, name}`; in any other Space it carries `space: null` and nothing
  else about where it came from. The rule "a Space not open to a plugin is unknown to it" holds.
- When the owner picks Ask Assistant: the app sends `ask(text, space)` to the plugin's
  background (`PluginWire.ask`, `singularity.onAsk(handler)` in `host.ts`), opens its panel
  (as ⌃⌘J does; if its page is a tab, it is moved to the panel, as Move to Side Panel does, so the
  owner stays on the home), and leaves the home tab as it is with the field cleared. The text is at most 20 000
  characters (the row refuses more, with a line saying so).
- Which plugin: the panel plugin the ⌃⌘J toggle would open, if it has `ask`; else the first approved
  one with `ask`. None: no Ask row.
- The Assistant (plugin, its own version bump): on `ask`, if it is ready (`status === "ready"`, no
  note waiting for OK) it sends the text as a new user message in its current conversation, exactly
  as if typed in its panel. Otherwise (starting, answering, a note up, the panel never opened this
  run) it puts the text into its input as an unsent draft, appended after anything already there, and
  the owner presses Send. The text is never dropped. `ask` stays one-way: the home gets no reply. Nothing else changes in it; it still
  knows the front tab only through `frontTab`, and the front tab is now the home (see below).
- `front` for a home tab: kind `"home"`, its id, the Space (only where the Space is on for the
  plugin, as for every tab today); no title or address.
- The text the owner typed is not logged by the app (it is the owner's own words to their own
  plugin, like typing in the panel).

### What agents and plugins see

- `list_tabs` leaves home tabs out; tab tools answer "not a web page" for a home tab id, as for a
  plugin tab. Nothing on the home reaches any agent, page or plugin; only `ask` text goes to the one
  plugin the owner sent it to.

### Where the code goes

- Core (`SingularityCore/Home/`): `HomeRules` (reuse, which tab a choice replaces, section order and
  hiding, the "new" mark, terminal ordering, recent-file merge and cut), all pure and tested.
- App (`Sources/Singularity/Home/`): `HomeView` (sections), `HomeSearchField` (the row, sharing the
  palette's result logic), wiring in `AppState` (`openHome()`, the replace-in-place path), the pane
  hosting the view for `.home`.
- Plugins: `PluginManifest` (`ask`), `PluginWire.ask`, `host.ts` `onAsk`, approval sheet text, the
  guide (`docs/plugins/AUTHORING.md`), Assistant `background.ts` + `plugin.json` version.
- Docs: a scope-change line in `CLAUDE.md` and the architecture entries; `IDEAS.md`: "Summarise"
  under approved follow-ups (owner said later).

## Left to the builder

- Exact look: spacing, fonts, colours, symbols; the visual pass is shown to the owner before merge.
- How the palette's result logic is split out so the home row and the palette share it.
- Test layout (Core tests for `HomeRules`; app tests in off-screen windows that never become key,
  with fake terminals and a fixture plugin for `ask`, never `claude`).
