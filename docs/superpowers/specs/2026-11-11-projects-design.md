# Projects in a Space: design

Status: **approved by the owner on 2026-11-11, built on 2026-11-12** (plan
`docs/superpowers/plans/2026-11-12-projects.md`). Sections marked "Builder's call" were chosen
by the writer; the owner read the list of them and approved the design as written. Differences
from this text are listed under "As built" at the end.

## Intent: why

A Space has one terminal folder. The owner's work Space covers two repositories,
`acme-web` and `acme-docs`, so every new terminal starts in the wrong place half the
time and needs a `cd`, and nothing in the sidebar says which repository a terminal belongs to.

While looking at mockups a second wish came up: the owner works task by task (a Jira ticket),
and wants the ticket page, the pull request and the terminals for that task to sit together.
The sidebar's folders already hold any mix of tabs, so that is a folder that knows its project.

## Words

- **Project**: a name and a folder on disk, listed on a Space. It decides where a terminal
  starts. Nothing else hangs off it.
- **Group**: the owner's word for a task's tabs kept together. It is today's sidebar `Folder`,
  with one addition: it can have a project. (Builder's call: the code and the interface keep
  saying "Folder"; no rename.)

## Goals

1. A Space lists its projects (name + folder), edited in Edit Space.
2. A new terminal starts in a project's folder. Outside a folder a small picker asks which one.
3. A sidebar folder can have a project. A terminal opened inside it starts there without asking.
4. The sidebar shows which project a terminal belongs to, without repeating what the folder
   header already says.
5. A Space with no projects never shows a picker and starts terminals in the Space's folder, as
   today. The one change it does get is where a new terminal lands (see "Opening a terminal").

## Non-goals

- Git anything: branch names, status, worktrees.
- Projects for web pages or artifacts. They sit in a folder; they have no project.
- Following the shell: a terminal that `cd`s into the other repository keeps its project.
- Per-project agent settings, policies or artifact folders. Those stay per Space.
- An agent tool that opens terminals, or a link to Jira. The owner makes folders by hand.
- Sharing projects between Spaces.

## Anti-goals

- The picker must not slow down the common case. Inside a folder with a project, New Terminal
  opens at once, as today.
- No sections decided by the project. The owner chose "grouped" in the mockups, then turned it
  into groups per task: tabs sit where the owner puts them.

## What the owner decided

- A small picker pops up with the projects when opening a terminal.
- The sidebar shows the project of a terminal.
- Groups per task hold web pages and terminals together.
- A task is usually in one repository, sometimes both. So: one project per folder, and a way to
  open the occasional terminal in another one.
- The playback below ("Behaviour") was read and accepted as a whole, including the parts that
  started as the writer's guesses.

## Behaviour

### Projects on the Space

Edit Space gets a "Projects" list under the three existing fields: add (choose a folder; the
name defaults to the folder's name and can be edited), rename, remove. Paths under the home
folder are stored as `~/…`, like the Space's own folder. The Space's "Terminal folder" stays and
is the fallback everywhere.

The welcome flow's "Your first Space" step is not changed (`SpaceFields` is shared; the list
goes in `SpaceEditorSheet`).

### A folder's project

A folder header's context menu gets "Project ▸" with "None" and the Space's projects, the
current one ticked. The header shows the project's name in small grey text at its right.

A folder inside another folder that has no project of its own uses the nearest enclosing
folder's project (Builder's call). Its header shows nothing in that case; only a folder's own
choice is shown.

### Opening a terminal

"Inside a folder" means: the selected tab is in that folder, or the terminal was opened from
the folder header's context menu ("New Terminal", new). The new terminal tab is then placed in
that folder. Today every new terminal lands in Tabs, whatever is selected. **Owner's decision:**
this placement applies in every Space, with or without projects, and every folder header gets
"New Terminal".

New Terminal (⌥⌘T, the sidebar button, the palette command):

| Where | What happens |
|---|---|
| Space has no projects | starts in the Space's folder, no picker (placed in the folder as above) |
| inside a folder with a project (own or inherited) | starts in that project's folder, no picker |
| inside a folder with no project | picker; the choice also becomes the folder's project (Builder's call) |
| not in a folder | picker |

"New Terminal in…" (⇧⌥⌘T, also in the palette; Builder's call on the shortcut) always shows the
picker when the Space has projects, and never changes a folder's project. This is the way to
get the other repository's terminal inside a task folder.

A terminal opened in a split (`openTerminalInSplit`) never shows the picker (Builder's call; it
is reached from the palette's split mode, and chaining two palette modes is not worth it). It
starts in, in this order: the project of the tab it is split beside when that is a terminal
with a project; that tab's folder's project (own or inherited); the Space folder. Beside a
terminal with no project it is the Space folder. It never sets a folder's project, and the new
tab is placed where split terminals are placed today.

Picking "Space folder" in the picker inside a folder with no project leaves the folder without
one, so that folder asks again next time. There is no "never ask here" state: the owner accepted
"a group with no project asks".

### The picker

A small list titled "New terminal in": the Space's projects, each with its path in grey, the
most recently used first, then the rest in the Space's order, then "Space folder" with the
Space's own path last. Arrow keys and Return, Escape cancels (no terminal opens), typing
filters. Return on a freshly opened picker therefore repeats the last choice.

Builder's call: build it as another mode of the existing command palette overlay
(`Sources/Singularity/Palette/`) rather than a new kind of window, so it gets the fuzzy filter
and the keyboard handling for free.

The last used project is remembered per Space, across launches. "Used" means chosen in the
picker; terminals opened without it (inside a project folder, in a split) do not change it, and
neither does choosing "Space folder" (Builder's call).

### In the sidebar

- Folder header: project name in grey at the right (above).
- Terminal row: a small tag with the project's name at the right of the row, before the agent
  badge and the close button, **only when it says something new**: the terminal has a project
  and it differs from its folder's project (own or inherited), or the terminal is not in a
  folder. A terminal started in the Space folder has no project and no tag.
- The tag follows the terminal. Dragging a terminal into another folder keeps its project; the
  tag appears or disappears by the same rule.
- In a split's row of chips there is no room for a tag; the chip's tooltip names the project
  (Builder's call).

Mockups from the conversation: `.superpowers/brainstorm/53289-1794391494/content/`
(`groups-with-projects.html` is the accepted one; not in git).

### Edges (Builder's calls)

- **Removing a project** from the Space: folders and terminals that pointed at it simply have no
  project any more (no tag, the folder asks again). Running shells are not touched.
- **Renaming or re-pointing a project**: names update everywhere; shells already running stay
  where they are.
- **The project's folder is missing on disk** when a terminal starts: whatever
  `TerminalSession` already does for a missing working directory. The picker still lists it.
- **A shell that exited and is restarted**, or tabs restored at launch: unchanged, they use the
  tab's stored working directory.
- **Arc import, onboarding**: make no projects.
- **Agents**: `list_tabs` adds `"project": "<name>"` to a terminal's entry when it has one.
  Nothing else changes in MCP.

## Data

All in `space.json`, all optional when decoding so older files load unchanged.

- `Space.projects: [Project]`, with `Project { id: UUID, name: String, path: String }`.
- `Space.lastProjectID: UUID?`.
- `Folder.projectID: UUID?`.
- A terminal tab's project: `BrowserTab.projectID: UUID?`. It cannot be derived from the working
  directory, because `AppState.terminalDidChange` rewrites `.terminal(workingDirectory:)` about
  once a second with the shell's current folder.

An id that matches no project in the Space counts as nil.

## Where the logic goes

The rules are pure and belong in `SingularityCore`, unit-tested: a folder's effective project,
which project a new terminal gets and whether to ask, the picker's order, whether a row shows
a tag. The app side only draws and calls them. `openTerminal` and `openTerminalInSplit` in
`AppState` are the two places that create terminal tabs today.

## Scope note

Projects are not a tab type, so this needs a "Scope change (owner decision, 2026-11-11)" line
in `CLAUDE.md` when the design is approved, plus the usual architecture notes once built.
No new dependency.

Build this after the onboarding work has landed: the design leans on `SpaceFields` and
`SpaceEditorSheet` as that branch leaves them.

## As built (2026-11-12)

Built as designed. Small things the design did not say, decided while building:

- The picker has no separate title: the palette's text field shows "New terminal in…" as its
  placeholder. The row of the last used project says "Last used" at its right.
- The folder header's "Project ▸" menu is only there when the Space has projects. "New Terminal"
  is always there.
- The palette's "New Terminal in…" command is only listed when the Space has projects. The menu
  item and ⇧⌥⌘T always exist; without projects they open a terminal like New Terminal.
- A project name longer than 18 characters is cut in the middle in the sidebar
  ("acme-web…monorepo"), so a tag cannot take the whole row. The tag keeps its width and the
  tab's title truncates instead.
- Clearing a project's name in Edit Space gives it its folder's name back on Save. "Add
  Project…" accepts several folders at once.
- No extra scope line was added to `CLAUDE.md`: the item is in `IDEAS.md`'s approved list, which
  the 2026-11-10 scope change already covers.
- A terminal row's tooltip names its project (also when the row shows no tag).
- Not exercised by hand: this was verified with unit tests, `AppState` tests and off-screen
  pictures of the sidebar and Edit Space. `IDEAS.md` lists what is left for a hands-on check.

## Left to the builder

Exact wording, sizes and colours; how the Projects list in Edit Space looks; whether the picker
mode reuses `PaletteItem` or has its own small item type; test layout.
