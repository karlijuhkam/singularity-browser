# Setup export and import: design

Status: **parked by the owner on 2026-11-13 as a future idea. Draft, not approved, nothing built.**
The two questions under "Open for the owner" (launchers, terminals) are unanswered. Sections and
sentences marked "Builder's call" were chosen by the writer, not by the owner. A reviewer read
the first draft against the code; its five points are worked in (terminals, what may loosen
security, removals, what "remove" does, file names).

## Intent: why

The owner changes laptops fairly often, and has moved browsers several times. Each time,
getting the browser back into shape (Spaces, pinned tabs, folders, settings, plugins) was the
annoying part. He wants that setup in a git repository, so a new Mac is set up in minutes, and
so two Macs used side by side can share the same setup.

Singularity already keeps everything it owns as plain files under `~/Singularity/`, but that
folder can't be the repository as it is: `space.json` mixes the setup with what belongs to one
machine (open tabs, splits, the selected tab), and next to it sit private or machine-bound files
(history, agent log, plugin approvals, sockets).

## Words

- **Setup**: the part of the browser the owner arranged on purpose and wants on every machine.
  Listed under "What is in the setup".
- **Setup folder**: a folder the owner chooses, holding the setup as files. He makes it a git
  repository himself. Singularity never runs git.

## What the owner decided

- The setup is shared between machines; **open tabs stay per machine**.
- Sessions (the open tabs following him) are wanted too, but **not through this**: a web service,
  later, as its own project.
- Two Macs side by side may happen, not only old laptop → new laptop.
- Start with export and import, the owner running git himself ("C"). The app committing,
  pulling and pushing by itself ("B") can come after.
- A Linux version is wanted one day. Not part of this; see "The format is a contract".

## Goals

1. File → "Export Setup…" writes the setup into the setup folder.
2. File → "Import Setup…" reads a setup folder and applies it, after showing what will change.
3. On a brand-new install the welcome flow offers the import, so a new Mac needs: install,
   `git clone`, Import Setup, sign in to the sites.
4. Exporting twice with nothing changed writes byte-identical files (no noise in `git diff`).
5. The files are readable and mergeable by hand: one small file per Space, sorted keys.

## Non-goals

- Running git, storing a remote, credentials, or a schedule. (The later step "B".)
- Open tabs, splits, history: anything that is "where I am" rather than "how I set it up".
- Logins. Cookies and site data live in WebKit's own store (`~/Library/WebKit/…`), which the
  app can't move. After an import every Space is logged out on that machine.
- Artifact files (Builder's call, see "Open for the owner").
- Automatic merging of two machines' changes. Git merges the text files; the import's preview
  is where the owner decides the rest.
- A Linux app.

## Anti-goals

- **The setup folder must never be able to loosen security on a machine by itself.** Whoever
  can push to the repository must not be able to approve a plugin, open a Space to agents, or
  change an agent policy on the owner's Mac. Those stay per machine and are never read from it.
- **An import must never lose something silently.** Everything it will do is in the preview
  first, and it never closes a tab: a tab that leaves the setup becomes an ordinary open tab.
- **A broken setup folder must never break the browser.** Git works only on the setup folder,
  never on `~/Singularity/`; a file with merge markers is reported and skipped.
- No secrets in the folder: no history, no agent log, no plugin data.

## Approaches considered

- **A. `~/Singularity/` is the repository** (split `space.json`, add a `.gitignore`). Least
  code, but git rewrites live files under a running app, a conflict leaves merge markers in a
  file the app must read, and the layout would be the Mac app's internals.
- **B. A separate setup folder the app writes and reads, and the app runs git** (commit, pull,
  push, a per-Space choice on conflict). The comfortable end state for two live machines; the
  most code.
- **C. The same setup folder, export and import by menu, the owner runs git.** Chosen by the
  owner as the first step. It is the first half of B: the folder format, the export and the
  import are exactly what B needs, so nothing is thrown away.

## What is in the setup

| In the setup folder | Stays on the machine |
|---|---|
| Space: id, name, slug, colour, emoji, terminal folder | Open tabs (not pinned, in no folder) |
| Space order | Selected Space, selected tab |
| Folders: id, name, nesting, project | Which folders are expanded |
| Projects: id, name, folder | The project last picked in the picker |
| Pinned tabs and tabs in folders, except terminals (see "Tabs") | Terminals, splits |
| | **Agents on/off, agent policy, the Space's console/network switch, per-site settings (camera, microphone, console/network, plugins off)** |
| Settings: search engine, terminal font and size, close on exit, approval timeout, launchers | Sidebar width and hidden, plugin panel, herdr-core switch, update switch, the setup folder's own location |
| Plugin source folders | **Plugin approvals** (`plugins-state.json`, incl. pinned program paths and which Spaces a plugin is on in), plugin data |
| | History, favicons, agent log, artifacts, `.run`, `.cache` |

Builder's calls in this table: everything in bold (the security line: a new machine starts
with agents off in every Space, every plugin waiting for approval and every site asking again
for camera and microphone, as a fresh install does); the herdr-core and update switches stay
per machine (they depend on what is installed there).

Two things that do travel can still do harm if someone else changes them in the repository:
a **launcher's command** (typed into the owner's shell at his next click) and the **search
address** (every palette search goes there). For these the preview is the consent, so it shows
them in full, old and new, never as a count: "Launcher Claude Code: `claude` → `claude
--dangerously-skip-permissions`".

### Tabs

Builder's calls, all of them:

- A tab is part of the setup when it is pinned or sits in a folder, and is not a terminal.
- **Terminals never travel.** A new terminal lands in the selected tab's folder, so task folders
  fill with short-lived terminals (one per agent session); written out, they would change the
  file with every session and arrive on the other Mac as dead tabs. A terminal is a session,
  and where terminals start already travels with the folder's project.
- An artifact tab travels as its path; without the file it shows the existing "file is missing"
  page. A plugin tab travels as the plugin's id.
- `openedByAgent` is not written.
- A web tab is written with its current address and title. Singularity has no fixed "pinned
  address": a pinned tab's address is wherever the owner last went in it. So on import, **a tab
  this machine already has (same id) keeps its own address and title**; only its place (pinned,
  folder, order) is taken from the file. A tab the machine doesn't have arrives with the file's
  address. Known cost: a pinned tab's address in the file changes as the owner browses, which
  shows up in `git diff`.

## The setup folder

```
<setup folder>/
  setup.json               { "format": 1, "spaceOrder": [<Space ids>] }
  settings.json            the settings listed above
  spaces/<name>.json       one per Space
  plugins/<id>/…           plugin source: no node_modules, .git, .DS_Store
```

- JSON is pretty-printed with sorted keys and a final newline, arrays in a stable order
  (sidebar order for tabs and folders), no dates, no machine names.
- Paths are written with `~` for the home folder, as `space.json` already does. A path outside
  the home folder is written as it is.
- Export touches only these four names. Anything else in the folder (`.git`, a README, the
  owner's own files) is never read, changed or removed.
- **A Space's file name** is its slug on the machine that first exported it, and never changes
  after that: a Space whose id is already in the folder keeps its file, even when this machine
  had to give it another slug (see Import). The file carries that first slug.
- Export is a mirror: `spaces/` and `plugins/` end up holding this machine's Spaces and
  plugins, except what "What this Mac has seen" below holds back.
- Symlinks and hard-linked files inside a plugin are refused, on export and on import, as the
  plugin fingerprint already refuses them.

### What this Mac has seen

Builder's call, added after the review. Without it the app can't tell "I deleted this here"
from "the other Mac added this", and both export and import would have to ask every time.

After every export and every import the app writes `~/Singularity/setup-seen.json`: the setup
folder's path and the ids of every Space, setup tab, folder, project and plugin that was in the
folder at that moment. Ids only, a few kilobytes, per machine, never exported. With it:

| In the folder | On this Mac | Seen before | Means | Export | Import |
|---|---|---|---|---|---|
| yes | no | no | new on the other Mac | stops: "Import first" | adds it |
| yes | no | yes | removed here | removes it from the folder | leaves it removed |
| no | yes | no | new here | writes it | leaves it |
| no | yes | yes | removed on the other Mac | stops: "Import first" | takes it out, shown in the preview |

A missing or unreadable `setup-seen.json`, or one for another folder, counts as "nothing seen":
the app then only ever adds, in both directions, and says so. The export's stop has no "export
anyway": the way on is always Import, which can no longer bring back what was removed here.

### The format is a contract

A Linux app may read this folder one day, and "B" will build on it. So: nothing Mac-only in it
(no bundle ids, no absolute program paths, no WebKit identifiers), `format` is a whole number,
a reader refuses a higher `format` than it knows with a plain message, and ignores keys it
doesn't know. (Known limit: an older app that imports and then exports drops keys a newer app
wrote. Acceptable while there is one app.)

## Import

1. The owner picks the folder (the last one is offered). The app reads it and builds a plan;
   nothing is changed yet.
2. A sheet shows the plan, in the owner's terms:
   - **New**: Spaces, plugins, and per Space the pinned tabs, folders and projects that will be
     added.
   - **Changed**: what will be updated, by name ("Work: colour, 2 tabs moved"), and the
     settings that differ.
   - **Removed on the other Mac**: what will leave this Mac's setup, each with a checkbox, on
     by default. Unticked, it stays, and the next export puts it back in the folder.
   - **Only on this Mac**: what is new here and not yet exported. Shown, not touched.
   - **Launchers and search**: every changed command and address in full, old and new.
   - **Skipped**: files that couldn't be read, with the reason.
   - Buttons: Cancel, Import. Nothing in the plan → "This Mac already matches the setup folder."
3. Import applies the plan.

Rules (Builder's calls unless the owner decided them above):

- **Matching is by id**, never by name: Spaces, tabs, folders, projects by their UUID, plugins
  by their folder name.
- **A new Space** gets the file's slug. If another Space here already has that slug, it gets
  the next free one (`Slug`); its agent tool names then differ between the machines, and its
  file in the folder keeps its name. Agents are off, policy "ask".
- **An existing Space** gets the file's name, colour, emoji, terminal folder, folders and
  projects. Its slug never changes (slugs are fixed at creation). Its open tabs, terminals,
  splits, selection, per-site settings, agent switch and policy are untouched.
- **Removing** happens only for ticked items, and means the least destructive thing:
  - a **tab** is not closed: it is unpinned and taken out of its folder, so it becomes an open
    tab of this Mac;
  - a **folder** goes the way Delete Folder does today: its tabs move up a level;
  - a **project** goes through `Space.setProjects`, which clears what pointed at it;
  - a **Space** goes through `deleteSpace` (folder to the Trash, its WebKit store removed), with
    its name and tab count in the preview. Not offered while any Space file was skipped;
  - a **plugin**'s folder goes to the Trash.
- **Plugins**: a new or changed plugin's files are copied into `~/Singularity/plugins/<id>`;
  the existing scan then shows it as needing approval (new) or paused (changed). Import never
  approves and never writes `plugins-state.json`. A plugin in development mode on this machine
  is never overwritten; it is listed under Skipped.
- **Settings**: the listed settings take the file's values; the launcher list is replaced as a
  whole, after the preview showed every command that changes, appears or goes. Applied through
  `AppState.updateSettings`.
- **A project whose folder doesn't exist on this machine** is kept as it is. A terminal that
  would start there starts in the Space's terminal folder instead, and Edit Space marks the
  project "folder not found". (The builder checks what happens today and adds only what is
  missing.)
- **One unreadable file skips that one item**, never the whole import, and a Space is applied
  completely or not at all.
- **The welcome flow**: step 1 gets "Import Setup…" beside "Import from Arc…". As with the Arc
  import, the imported Spaces replace the untouched placeholder Space, and the flow goes on at
  step 3.

## What the owner sees

File menu, under "Import from Arc…": "Export Setup…" and "Import Setup…"; both also in the
command palette. The first export asks for a folder (a normal folder panel, "New Folder"
allowed) and remembers it in `settings.json` on this machine. After an export: one line, "Setup
exported to ~/Developer/singularity-setup", with "Show in Finder". The app says nothing about
git.

The new-Mac path, start to end:

```
install Singularity
git clone git@github.com:me/singularity-setup.git ~/Developer/singularity-setup
Welcome → Import Setup… → pick the folder → Import
Settings → Plugins: approve each plugin.  Settings → Agents: switch agents on where wanted.
Sign in to the sites.
```

The two-Mac routine: `git pull`, Import Setup on arriving; Export Setup, `git commit`, `git push`
on leaving.

## Constraints

- Scope: sync is on the v1 out-of-scope list and this is not a tab type. Approving this design
  is the scope change; `CLAUDE.md` gets a line for it, e.g. "**Scope change (owner decision,
  <date>):** setup export and import are in: the setup (Spaces, pinned tabs, folders, projects,
  settings, plugin source) is written to and read from a folder the owner keeps in git himself.
  Still out: the app running git, open tabs or history leaving the machine, accounts."
- No new dependency.
- All rules are pure functions in `SingularityCore` (a new `Setup/` folder: the file types,
  Space → file, file + Space → Space, the plan), unit-tested. The app side is file reading and
  writing, the two menu items and the sheet.
- Tests and trials use temporary folders and `TestAppState` only: never the real
  `~/Singularity/`, never a real repository of the owner's.
- Writes are atomic. An export that fails part-way must say so; the owner sees the half-written
  state in `git status`.

## Left to the builder

- Type and file names in Core, the sheet's layout, exact wording of messages.
- The order of setup tabs that exist on both sides versus only here, as long as the file's
  order is kept among the file's tabs.
- Where new Spaces land in the rail (after the existing ones, in the file's order, is fine).
- How the plan describes a changed Space, as long as it names the Space and what changes.
- Whether a split that contains a removed tab needs more than what removing a tab does today.

## Open for the owner

1. **Terminals never travel**, pinned ones included. The alternative: pinned terminals outside
   folders travel, with the folder they start in.
2. **Launchers travel, and the preview is the guard.** A launcher's command is typed into the
   shell, so a changed command in the repository is a way to run something as the owner. The
   design shows every changed command in full before Import. The stricter alternative:
   launchers stay per machine and are set up by hand on each Mac.
3. **Agent switches, plugin approvals and per-site settings stay per machine.** Safer; costs a
   few minutes in Settings on each new Mac, and sites ask again for camera and microphone.
4. **The app remembers which ids it has seen** (`setup-seen.json`), so removals travel and an
   export can't silently drop the other Mac's additions.
5. **Artifacts stay out.** They are generated files, can be large, and belong to the work more
   than to the setup. If they should travel: `spaces/<slug>/artifacts/` in the setup folder.
6. **A pinned tab keeps its own address per machine** once both have it.
