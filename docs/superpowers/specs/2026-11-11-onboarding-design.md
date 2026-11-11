# First-run onboarding and the live orb: design

Status: **built on 2026-11-11.** The owner said "build it, I'll review in the end"
(2026-11-11). What the owner decided is under "Decided by the owner"; everything under
"Designer's calls" was chosen by the designer, was built without the owner confirming it one by
one, and is still open to that final review (call 3, the slug, in particular). Where the build
differs from this design, what nobody could check by hand, and the small known issues are under
"As built" at the end.

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

## As built (2026-11-11)

Built on branch `onboarding` (commits `e888224` to `2196d94`, plus this documentation). The
designer's calls 1–14 were all built as written. None was confirmed by the owner one by one, so
all fourteen are still open to the final review, call 3 (the slug) most of all. Below: where the
build differs from the design or fills in what was left to the builder, what nobody could try by
hand, and the small known issues left for the owner.

### Differences and the builder's choices

**The orb**

- It is an `MTKView` (AppKit, wrapped for SwiftUI), not drawn by SwiftUI itself.
- The shader is Metal source in a Swift string, compiled when the app runs (`makeLibrary(source:)`,
  `OrbShader.swift`). So there is no `xcrun metal` build step, and the bare debug binary gets the
  live orb too. The PNG fallback shows only without a Metal device or when the shader fails to
  compile.
- 30 frames a second. It does **not** stop after a while without pointer movement. Measured on an
  empty Space: about 2–3 % CPU in steady state (`top` 1.6–3.4 %, `ps` 2–5 % over 10–35 s), 0 %
  when the window is covered. The design says to lower the rate or stop if the cost is not
  negligible; the builder judged this acceptable, and the owner may not.
- Paused when the view is not in a window, when the window is covered, and when the app is
  hidden (⌘H).
- Reduce Motion: one still frame (time 4, the default ripple origin); the pointer is ignored.
- The "Check" became a test, `OrbTests.matchesTheSiteShader`, against `render_orb.py --time 4.0`
  frames in both colours. Its limit is a mean difference of 8 (of 255) instead of the planned 6.
  Why: in 7 of the noise function's 49 corners the exact maths gives 0, and the GPU's float32
  and numpy's float64 round it to opposite signs. With the reference rounded as float32 the port
  differs by only 0.19 (white) and 0.14 (black). So the port matches the site, which also runs
  float32 on the GPU; the rest of the difference is in the numpy reference.

**Connect**

- Codex is checked by reading `~/.codex/config.toml` with a small line scanner, not with
  `codex mcp get`. It understands `[mcp_servers.singularity]` (also quoted) and an inline
  `singularity = { command = … }` under `[mcp_servers]`. Dotted keys and multi-line strings read
  as "not connected", which the design allows.
- The programs run through the user's login shell: `$SHELL -l -i -c`, home as the working
  directory, no input, 20-second timeout. "Installed" means `command -v <program>` exits with 0.
  Checked on the owner's Mac by the controller: it finds `claude` (a shell function) and `codex`
  (under nvm) in about 0.8 s. The real `claude mcp add -s user …` and `codex mcp add …`, run
  against throwaway `CLAUDE_CONFIG_DIR` / `CODEX_HOME` folders, wrote exactly the shapes the
  check reads, a path with a space included.
- An existing entry is reported even when the program is not found (it may only be missing from
  the login shell's PATH).
- The "Points at another copy" row also shows the path the entry points at.
- If Update's re-read still shows another path, the row says "Points at another copy" again, not
  an error. If an add succeeds but the file has no entry, the row says "The agent did not keep the
  entry."
- Update is remove, then add. If the remove works and the add fails, the old entry is gone; the
  row shows the add's error and the command to copy.
- An error shows the program's own output, at most its last 300 characters. A failed row has no
  retry button; opening the step (or Settings → Agents) again checks again.
- Settings → Agents: the section is now "Connect agents" ("Gives these agents the Singularity
  tools in every project."), with the same rows. The "isn't in /Applications" note stays.
- The app's shell type is `AgentLoginShell`, because Core already has a `LoginShell` (terminal
  tabs).

**The flow**

- Sizes scale with the window, from the minimum window (820×520: orb 220 pt on step 1 and 150 pt
  after, title 30 pt, column 440 pt) to about 1500×1000 (340/240 pt, 36 pt, 520 pt).
- Title and text are pinned at the top and the footer at the bottom of a column of fixed height,
  the same on all four steps. A step's controls scroll in between when the window is short. So
  step 1, which has no controls, has an empty middle.
- The orb side is hidden when the column would get less than 420 pt beside it (below about
  768 pt of width). The app's minimum width is 820, so in practice the orb always shows.
- Footer: step dots and a quiet "Skip setup" on the left; Back, the step's secondary button and
  the primary on the right. Steps 2 and 3 show Back, Skip and Continue together. After an Arc
  import there are three dots.
- Step 2 uses the shared `SpaceFields` in a roomier style (labels above the fields, a larger name
  field and colour dots). Edit Space renders exactly as before (its render is byte-identical).
  Continue is disabled while the name is blank. The title stays "Your first Space" when the flow
  is reopened from the menu.
- Step 3: each Space's switch has the Space's colour dot next to it.
- Step 4: while a plugin is being copied, its row shows a spinner and Start browsing and Back are
  disabled, so the approval sheet that follows can't be lost. Skip setup and Esc stay enabled.
  "Copied" turns back into "Copy" after two seconds. With no bundled plugins (the bare debug
  binary) the list is left out and only the prompt shows.
- Leaving: besides Skip setup, Esc, Start browsing, the menu commands and the palette, the flow
  also closes for the approval sheet's "Show Tab" (`showTab`), `openInNewTab` and
  `openArtifact`. So an artifact page that calls `singularity.open` closes a flow reopened from
  the menu. (On a brand-new install there is no artifact page behind the flow.)
- The placeholder status, and with it the slug exception, ends as soon as the Space gets its first
  tab by any route (an agent, a new artifact file, …) and when the flow closes.
- Arc import from step 1 removes the placeholder with `deleteSpace`, which moves its folder (by
  then holding an empty `artifacts/`) to the user's Trash. If nothing was imported, the flow stays
  on step 1.
- `ArtifactHosts.stop` now also cancels a server start that is still pending, and
  `ensureArtifactHost` re-reads the Space by id. Without this, the start queued at launch
  recreated `spaces/personal/artifacts` after the rename. It also fixes an older edge case:
  deleting a Space while its server was starting.

**Bundling.** The ready-made plugins go to `Contents/Resources/Plugins/<id>/`, the guide and the
template to `Contents/Resources/plugin-guide/{AUTHORING.md, template/}`. Both scripts copy them
with `rsync`, leaving out `node_modules`, `.git` and `.DS_Store`, before signing.
`codesign --verify --deep --strict` passes on the built bundle. `release.sh` was checked by
reading, not run.

### Not checked by hand

The build environment had no macOS Accessibility permission, so nobody could click, type or move
the pointer in the running app. A test copy (`SINGULARITY_HOME=/private/tmp/sg-test`, full bundle
in `/private/tmp/sg-app`) was looked at in screenshots, partly through temporary hooks that were
removed before each commit. Seen that way: the flow on a fresh data folder, the orb animating,
step 3's rows (Claude Code "Points at another copy" with Update, because the owner's entry points
at `build/`; Codex "Connect"; the Space switch off), step 4 with 1Password and Add, the approval
sheet after Add, "Review…" after a relaunch, no flow on the second launch, and the orb in an empty
Space.

| Not tried by hand | What covers it |
|---|---|
| Pointer following on the orb (tracking area, easing) | `OrbTests.pointerBecomesAPointOnTheSphere` covers the maths from pointer to point on the sphere. Tracking and easing: nothing. |
| The black orb in light mode on screen | `OrbTests.matchesTheSiteShader(whiteOrb: false)` renders it; one screenshot with the app's appearance forced to light (a temporary hook) showed it. Following a live change of the system appearance: nothing. |
| Reduce Motion (still frame) | Nothing. |
| Pausing on ⌘H | Nothing. (Pausing when covered was seen in logs: 0 % CPU.) |
| The PNG fallback | Nothing (this Mac has Metal). |
| Connect and Update against the real Claude Code and Codex | `AgentConnectorTests` with a fake shell (`connectRunsTheAddCommandAndRereadsTheConfig`, `updatingAnotherCopyRemovesThenAdds`, `failingAddShowsTheProgramsOutput`, `addThatLeavesTheFileUnchangedFails`), and the controller's run of the real commands against throwaway config folders. Whether `claude mcp add` through the owner's `claude` shell function writes to the default `~/.claude.json`: nothing. |
| Picking a colour in step 2 | `OnboardingStateTests.renamingThePlaceholderMovesItsFolder` saves a colour through `applyWelcomeSpace`. The swatch click: nothing. |
| Typing a name and Continue | `OnboardingViewTests.returnTypingAndEscapeDriveTheFlow` types "Work" into the real view in an off-screen window and checks that only `spaces/work` exists. Not in the running app. |
| Cancelling the approval sheet by hand | Nothing. The "Review…" row it leads to was seen after a relaunch. |
| Copy → pasteboard (the prompt and the commands) | Nothing. |
| Choosing the menu item "Welcome to Singularity…" (and the palette entry) | Their action, `showWelcome()`, in `OnboardingViewTests.returnTypingAndEscapeDriveTheFlow`. The menu item itself: nothing. |
| ⌘T on step 1 | `OnboardingStateTests.stepsAndLeaving`: `showPalette(.newTab)` closes the flow and opens the palette. The keystroke: nothing. |
| Arc import through the real sheet | `OnboardingStateTests.anArcImportReplacesThePlaceholder` (calls `importArcSpaces`) and `stepsAndLeaving` (opening the sheet keeps the flow). The sheet with Arc's real file: nothing. |
| "Start browsing" into the Space, as one sequence in the real app | `returnTypingAndEscapeDriveTheFlow` (Return on step 4 closes the flow); the empty-Space orb was seen on a second launch. |

### Known small issues, left for the owner

From the task reviews; none blocks use.

- **Orb:** one test limit (8) for both colours, though black measures 0.74 (`OrbTests.swift`;
  could be `whiteOrb ? 8 : 2`). The scene constants (radius, camera z, 0.96) are written twice,
  in Swift and in the shader string (`OrbShader.swift`). The shader compiles on the main thread
  the first time an orb is shown (`OrbView.swift`).
- **Connect:** in the Codex scanner a multi-line array under the `singularity` table ends the
  section early (wrongly "not connected"), and a relative or empty registered path is compared
  against the app's working directory (`AgentConnect.swift`). `connect` only refuses while a row
  is working; it should only run from "not connected" or "another copy" (`AgentConnector.swift`).
  An Update whose re-read still shows another path gives no hint that it did not work. A
  translocated app shows both the row's message and the "/Applications" note in Settings →
  Agents. Missing tests for the 300-character cut and for a check leaving a working row alone;
  those tests' temp folders are not removed (`AgentConnectorTests.swift`).
- **Bundled plugins:** the sort test cannot tell name order from folder order
  (`BundledPluginsTests.swift`). The copy block is duplicated in `build-app.sh` and `release.sh`,
  as their other steps are.
- **Flow and state:** `OnboardingStateTests` waits 300 ms for the artifact server instead of
  polling with a deadline. Stopping an artifact server on purpose logs "artifact server stopped:
  failed(kqueue …)", which reads like an error and shows up in test output (`ArtifactServer.swift`).
  `toolsChanged()` is sent twice when a rename changes the slug (`AppState.swift`). In
  `OnboardingViewTests` a check counts exactly two shell lines, which is brittle, and there are no
  tests for "Skip on step 2 does not save" or for Continue being disabled with a blank name. The
  two design consequences above (the placeholder's folder goes to the Trash after an Arc import;
  an artifact page's `open` closes a reopened flow) were planned that way.

Where things are: `Sources/SingularityCore/Onboarding/`, `Agent/AgentConnect.swift`,
`Plugins/BundledPlugins.swift` (Core, with `OnboardingTests`, `AgentConnectTests`,
`BundledPluginsTests`); `Sources/Singularity/Onboarding/`, `Orb/`, `Agent/AgentConnector.swift`,
`Agent/AgentConnectRows.swift`, `Sidebar/SpaceFields.swift` (app, with `OnboardingStateTests`,
`OnboardingViewTests`, `AgentConnectorTests`, `OrbTests`).
