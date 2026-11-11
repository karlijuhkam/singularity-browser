# First-run onboarding and the live orb: design

Status: **the owner said "build it, I'll review in the end" (2026-11-11).** What the owner
decided is under "Decided by the owner"; everything under "Designer's calls" was chosen by the
designer, was not confirmed one by one, and is open to that final review (call 3, the slug, in
particular).

## Intent: why

A new user who opens Singularity today gets a silently created Space called "Personal" and one
line of text ("Press ⌘T to open a tab, or ⌥⌘T for a terminal"). Nothing tells them what a Space
is, that their coding agents can drive the browser, or that plugins exist. The three things that
make Singularity different are the three things a newcomer cannot find.

The owner wants a first-run screen in the spirit of Arc's onboarding, but shorter, after which
the user has:

1. made at least one Space their own,
2. connected their agent (as automatically as possible),
3. seen the ready-made plugins and learned that an agent can write one.

The owner also wants the orb from singularity.rroosa.ee to be alive in the app. Today it is a
static image.

## Decided by the owner

- The flow is the four steps of the approved mockup
  (`.superpowers/brainstorm/68702-1794387788/content/onboarding-flow.html`, git-ignored; the
  steps are described in full below, so the file is not needed to build this).
- Feel: Arc's onboarding, shorter. It takes over the whole window.
- Agents that get a Connect button: **Claude Code** (the main one) and **Codex**.
- The "let agents use this Space" switch in the agents step starts **off**. The user switches it
  on. Connecting an agent and opening a Space to agents stay two separate acts.
- The screen appears by itself **only on a brand-new install**. Existing users never see it
  unasked. A **menu item** opens it again at any time.
- The plugin step shows **both** a list of ready-made plugins and how an agent can write one.
- The **live orb** is used in the onboarding screen **and replaces the static orb** shown in an
  empty Space.
- The Claude Chat plugin is a separate project, designed after this one (see `IDEAS.md`).

## Goals

1. On a brand-new install the first thing the user sees is the welcome flow, not an empty Space.
2. The flow is four short steps, each skippable, finishable in under a minute.
3. One click connects an installed Claude Code or Codex to this copy of Singularity.
4. A bundled plugin can be added from the flow through the normal approval sheet.
5. The orb is drawn live by a native shader that matches the site's.
6. Everything the flow does can also be done later in the places that already exist (Edit Space,
   Settings → Agents, Settings → Plugins). The flow adds no capability of its own.

## Non-goals

- The Claude Chat plugin, and any plugin that does not exist yet.
- Agents other than Claude Code and Codex. They keep the command to copy.
- A tour of the interface (tooltips, coach marks, highlighted buttons).
- "Set as default browser", accounts, sign-in, telemetry, sync, themes.
- Importing from browsers other than Arc.
- Creating several Spaces in the flow. One is customised; more come from Import from Arc or
  later from New Space.
- A web-based screen. This is app chrome: SwiftUI/AppKit only, and the orb is not a web view.

## Anti-goals: these would make it a failure even if it works

- **An agent gets access the user did not give.** No Space is opened to agents by the flow
  unless the user flips its switch. The policy stays "ask". Connecting never flips a switch.
- **A plugin runs without the approval sheet.** "Add" in the flow must go through exactly the
  same approval as Settings → Plugins → Add Plugin….
- **The flow traps or nags.** Every step can be skipped, the whole flow can be left at any
  point, quitting halfway leaves a normal working browser, and it never reappears by itself.
- **The orb costs noticeable energy.** An empty Space left open all day must not keep the GPU or
  CPU visibly busy (see "The live orb").
- **The app changes another program's settings silently.** Connect runs only on the user's
  click, the row says what it will do, and the result (or the error) is shown.

## When it appears

- **Brand-new install:** the store loaded no Spaces and reported no load errors, so the app
  created its first Space (`AppState.init`, today's "Personal"). In that launch the welcome flow
  is shown. No flag is stored: after the first launch a Space exists on disk, so the next launch
  is not brand-new. A data folder whose Space files are all unreadable is **not** brand-new (it
  has load errors): the existing alert is shown and the flow is not.
- **Menu:** "Welcome to Singularity…" in the Singularity (app) menu, and the same entry in the
  command palette. It opens the same flow from step 1.
- While the flow is open it replaces the whole window content (sidebar and content area). The
  menu bar keeps working; choosing e.g. New Tab closes the flow and does the command.

## The four steps

Layout, as in the mockup: the live orb on the left (about 40 % of the width, large on step 1,
smaller afterwards), the step on the right with a title, one or two sentences, the controls, and
a footer with step dots, a secondary action and the primary button. Return triggers the primary
button. From step 2 on there is a Back button.

**Leaving.** Every step's footer has a quiet "Skip setup" that closes the whole flow, and Esc
does the same. Steps 2 and 3 also have "Skip" (go to the next step without applying this one).
Only "Continue" on step 2 saves the Space fields; Skip, Skip setup, Esc and Back discard what was
typed there. Things done by a click (Connect, a switch, Add) take effect at once and stay done
however the flow is left.

Wording below is a starting point; the builder may
polish it but keeps it short and plain.

### 1. Welcome

- Title "Welcome to Singularity". Text: "A browser built around Spaces. Web pages, terminals and
  the pages your agents make sit side by side in one sidebar."
- Primary: "Get started" → step 2.
- Secondary: "Import from Arc…", shown only when Arc's sidebar file exists. It opens the existing
  `ArcImportSheet`. After a successful import the flow continues at **step 3** (the Spaces came
  from Arc, so there is nothing to customise), and on a brand-new install the untouched
  placeholder Space made at launch is removed (it has no tabs; the imported Spaces replace it).
  Cancelling the sheet stays on step 1.

### 2. Your first Space

- Text: "A Space keeps its own tabs, logins and working folder."
- Controls: name, colour (the eight presets), folder for terminals: the same three fields, with
  the same behaviour, as `SpaceEditorSheet`. Share the controls rather than copying them.
- It edits a Space that already exists: on a brand-new install the one made at launch; when the
  flow was reopened from the menu, the selected Space.
- Primary: "Continue" saves and goes to step 3.
- **The slug.** A Space's slug is normally fixed at creation, and agents see it in tool names
  (`personal.read_page`). On a brand-new install the user has not chosen anything yet, so when
  they name the Space "Work" here, the slug must become `work`, not stay `personal`. This applies
  only to the placeholder Space of a brand-new install, in this step, while it has no tabs. When
  the flow is reopened from the menu, renaming follows the normal rule (display name only).

### 3. Connect your agent

- Text: "Agents you already use can drive this browser. They ask before acting."
- One row per agent, Claude Code then Codex, each in one of these states:

  | State | Row shows |
  |---|---|
  | checking | a spinner (the checks run when the step appears, not at launch) |
  | agent not found on this Mac | "Not found", and the command to copy |
  | found, not connected | "Connect" button; a caption says what it does ("Adds Singularity to Claude Code's MCP servers") |
  | connected to this copy of the app | "Connected ✓" |
  | connected to a different copy (another path) | "Points at another copy of Singularity", and an "Update" button |
  | Connect failed | the program's error text, and the command to copy |
  | app runs from a temporary (translocated) path | no button; "Move Singularity to the Applications folder and reopen it" (same rule as Settings today) |

- Below the agents: one switch per Space, "Let agents use ‹name›", caption "They ask before
  clicking or typing". **Off by default.** On a brand-new install that is one switch; after an
  Arc import, one per Space. It sets `agentsEnabled` through the same path as Settings → Agents
  and leaves the policy at "ask".
- Secondary: "Skip". Primary: "Continue". Neither depends on anything being connected.

**What Connect does** (verified against Claude Code 2.1.322 and codex-cli 0.163.0 on
2026-11-11; verify again when building):

- Claude Code: `claude mcp add -s user singularity -- <launcher>`.
- Codex: `codex mcp add singularity -- <launcher>`.
- **The check must not start the registered server.** `claude mcp get` health-checks the entry,
  which runs the registered `singularity-mcp`; that launcher can start or connect to another copy
  of the app (the owner's real one during a `SINGULARITY_HOME` trial). So the check only *reads*
  where the entry points:
  - Claude Code: the user-scope entry is `mcpServers.singularity.command` at the top level of
    `~/.claude.json` (seen on the owner's Mac; per-project entries live under `projects.<path>`
    and are ignored). Read-only; never write this file, changes go through `claude mcp add/remove`.
  - Codex: the entry is in `~/.codex/config.toml` under `mcp_servers.singularity`. Read the
    command from there, or use `codex mcp get singularity` if the builder confirms it does not
    start the server (it prints "No MCP server named 'singularity' found." when absent).
  - An unreadable or unexpected file counts as "not connected", never as an error that blocks
    the step.
- `<launcher>` is `Contents/MacOS/singularity-mcp` of the running app, as in
  `AgentSettings.launcherPath`.
- "Update" removes the old entry (`mcp remove singularity`) and adds the new one.
- After Connect or Update the app runs the check again and shows what the check says, not what
  it hoped for.
- All of this runs with the home folder as the working directory, so Claude Code's per-project
  ("local") entries do not confuse the check, and with a timeout.

**Finding and running the programs** is left to the builder, with these facts from the owner's
Mac as test cases: an app started from the Dock has a minimal `PATH`; `codex` is a Node script
under `~/.nvm/…/bin` (it needs `node` on the `PATH` to run at all); `claude` is wrapped by a
shell function in the owner's `.zshrc` that picks a second config folder for one project. Running
the commands through the user's login shell, the way terminal tabs start, handles all three, and
is the suggested route. A user with several Claude config folders gets only the default one
connected; the copyable command covers the rest. That limit is accepted.

**Settings → Agents** gets the same rows (Connect buttons for both agents, plus the copyable
commands), from the same code. Today it only shows the Claude command.

### 4. Plugins

- Text: "Small add-ons you can read and approve."
- A list of the plugins shipped inside the app. Today that is 1Password only. Each row: name, one
  line from its manifest, and "Add". "Add" installs the bundled folder the way
  `PluginInstaller.add` does and brings up the normal approval sheet. A plugin that is already in
  `~/Singularity/plugins/` and approved shows "Added"; one that was copied but not approved (the
  sheet was cancelled) shows "Review…", which brings the approval sheet back.
- Under the list: "Or have your agent write one:" and a prompt in a box with a Copy button. The
  prompt names the authoring guide's path inside this copy of the app and the plugins folder,
  e.g. "Read ‹path›/AUTHORING.md, then write a Singularity plugin in ~/Singularity/plugins/ that
  …".
- Primary: "Start browsing" closes the flow and leaves the user in their Space.
- The list is built from what is in the bundle, so a plugin added to the app later (Claude Chat)
  appears without changing this screen.

**Bundling.** `scripts/build-app.sh` and `scripts/release.sh` do not copy `Plugins/` or the guide
into the app today. They must copy the ready-made plugins (not `template/` into the list, though
the template should ship next to the guide so the prompt can point at it) and
`docs/plugins/AUTHORING.md` into `Contents/Resources/`.

## The live orb

- **What it is.** The site draws the orb with one fragment shader (`IridescentWaveMaterial`:
  ripples from a point, embossed lighting, fresnel edge, an RGB rim whose three lobes circle the
  edge). `scripts/icon/render_orb.py` is a faithful numpy port with the scene constants (camera
  at z = 6, sphere radius 2.2, default ripple origin (-1.5, -1.5, 0.5)). The native orb is a port
  of the same maths to a Metal shader, drawn by SwiftUI, in one reusable view.
- **Colour.** As now: white orb in dark mode, black orb in light mode (`uColor`), following the
  system appearance.
- **Pointer.** As on the site: while the pointer is over the orb, the ripple origin moves to the
  point under it, easing towards it (the site blends 10 % per frame); otherwise it stays where it
  was.
- **Where.** The onboarding screen, and the empty-Space placeholder in `ContentArea`
  (`MainView.swift`), which keeps its 96-point size, Space name and hint line. The Dock icon and
  app icon stay static images.
- **Energy.** The orb animates only while its view is on screen in a visible window. With
  "Reduce motion" on, it is a still frame. The builder picks a frame rate that looks smooth and
  checks the energy impact of an empty Space left open; if it is not negligible, lower the rate
  or stop animating after a while without pointer movement.
- **Fallback.** If the shader cannot be loaded (e.g. the bare debug binary run without a bundle),
  show the existing `Orb-dark/-light.png`. Keep those files.
- **Build.** No new dependency. The shader has to reach the bundle compiled; SwiftPM on the
  command line may not do that by itself, so the build scripts may need a step using the Metal
  compiler from the Xcode they already use (`xcrun metal`, present in `/Volumes/Zealot/Xcode.app`).
  The builder verifies which way works and documents it in `CLAUDE.md`.
- **Check.** A frame of the native orb at a fixed time should look the same as
  `render_orb.py --time` at that time, in both colours. A visual comparison is enough.

## Constraints

- Swift + SwiftUI, AppKit where needed; macOS 14+; no new dependencies; boring, commented Swift
  (the owner reads TypeScript/PHP more easily than Swift).
- Logic that can be pure goes in `SingularityCore` with unit tests: deciding whether a launch is
  brand-new, the step sequence (including the jump after an Arc import), building the agent
  commands and quoting the launcher path, reading the result of the `mcp get` checks, the
  translocation rule, listing bundled plugins.
- App tests follow the existing pattern (`Tests/SingularityAppTests`, nested in `AppTests`).
- Never run `scripts/build-app.sh` or `scripts/run.sh` against the owner's running copy; try the
  flow with `SINGULARITY_HOME=/private/tmp/sg-test` (a fresh folder is a brand-new install). The
  real `claude`/`codex` configs must not be changed by tests: the code that runs the agent
  commands takes the program as a parameter so tests can pass a fake.
- No pane-header pitfalls: the flow covers the title-bar strip, so do not put SwiftUI `.help()`
  on controls there (see `CLAUDE.md`, split view).

## Designer's calls (open to review)

1. **No "Claude Chat — Soon" row.** The mockup showed one; the design lists only plugins that
   ship, because the project rule is not to leave placeholders for unbuilt things.
2. **A Back button** from step 2 on (Arc has one; the mockup did not show it).
3. **The slug follows the name** chosen in step 2 on a brand-new install (otherwise a user who
   names their Space "Work" gets agent tools called `personal.…` forever).
4. **Arc import jumps to step 3** and removes the empty placeholder Space.
5. **One agents switch per Space** in step 3 (matters only after an Arc import).
6. **"Connected to another copy" + Update** rather than silently repointing an existing entry.
7. **No stored "seen" flag**; brand-new is "no Spaces and no load errors at launch".
8. **Menu item in the app menu**, named "Welcome to Singularity…", plus a palette entry.
9. **Settings → Agents gains the same Connect rows**, including Codex.
10. **Reduce motion → still orb**, and the PNG as fallback.
11. **Only the default Claude config folder** is connected by the button.
12. **"Skip setup" and Esc on every step**; leaving step 2 without Continue discards the edits.
13. **The connection check reads the agents' config files** instead of asking the agents, so it
    never starts a server.
14. **"Review…"** on a bundled plugin that was copied but not approved.

## Left to the builder

- View structure, animation between steps, exact sizes and spacing, final wording.
- How the programs are found and run (within "Finding and running the programs").
- How the shader is compiled into the bundle and loaded.
- The orb's frame rate and idle behaviour (within "Energy").
- Where bundled plugins live inside `Contents/Resources/`.
- Updating `CLAUDE.md`, `README.md` and `IDEAS.md` when built.
