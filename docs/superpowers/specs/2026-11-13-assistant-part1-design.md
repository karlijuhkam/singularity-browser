# Assistant (the built-in helper), part 1: a plugin's own panel and tab, a running program, a plain chat: design

Date: 2026-11-13. Status: written for the owner's approval; nothing is built yet.

## Why

The owner wants a helper built into Singularity, in their words:

- "i want to build Claude agent plugin. Id like it to work either in a tab or in a sidebar at right."
- "for asking about the page im looking at, without a terminal. to drive the browser and other
  sessions. i see it as a more built in helper … you browse with the agent, so basically this is the
  Dia alternative in Singularity."
- "the helper is the one that helps to be on top of this work as it gets confusing fast if youre
  working on multiple things at once. so maybe even as a one agent or a bot that sees what is
  happening in every space"
- On paying for it: "im all for using users claude … they are already paying for this and probably
  dont want to pay extra for api".

This is the "Claude Chat plugin (top priority)" of `IDEAS.md`. It is three projects, built in this
order, each with its own design:

1. **Part 1 (this document): the ground floor.** A plugin can show its own page in a panel at the
   right of the window or in a tab, and can keep one approved program running and talk to it. The
   Assistant plugin uses both to give a plain chat on the user's own Claude Code sign-in. It cannot see
   pages or act yet.
2. **Part 2: browse with the helper.** It knows the page in front, reads it and acts in the browser,
   through the door agents already use (`singularity-mcp`), under each Space's policy, approvals and
   agent log.
3. **Part 3: on top of the work.** It sees the terminals of every Space the owner lets it see, and
   can type into one only after the owner approved the exact text, every time (owner decision).

**Name (owner decision):** the plugin is called **Assistant**. "Agent" was tried first and dropped
by the owner because the app already says "agents" for outside agents ("it will get confusing,
lets use Assistant"). Its id and folder are `assistant`. Other providers may come later (owner:
"maybe bring in other providers too later"); part 1 has one, Claude.

Everything below marked **(my call)** was decided by the writer, not said by the owner.

## What success looks like (part 1)

1. A fresh copy of Singularity lists "Assistant" among its bundled plugins. The owner adds it; the
   approval sheet says in plain words that it shows its own panel and tab and that it keeps
   `/Users/…/claude` running, a program that uses the internet and acts as the user.
2. The owner presses the panel's shortcut. A panel opens at the right of the window, beside the page.
   They type "hello"; the answer streams in word by word. No terminal, no key, no login in
   Singularity: it used the Claude Code sign-in already on the Mac.
3. They switch tabs and Spaces. The panel stays where it is, with the same conversation.
4. They choose "Open as Tab". The same conversation is now a tab in the sidebar and the panel is
   closed; "Move to Side Panel" puts it back.
5. They quit and start Singularity again. The last conversation is there and can be continued.
   "New Chat" starts an empty one.
6. On a Mac where Claude Code is signed out, the chat says so and says what to do. Where it is
   missing, the plugin cannot be approved (as for any missing program today) and the panel shows
   the app's own "isn't running" page with that reason.

## Goals, non-goals, anti-goals

**Goals:** the two new plugin abilities (own page in a panel or tab; one running program), built
only as far as the Assistant plugin needs them; the Assistant plugin with a plain streaming chat.

**Non-goals for part 1** (not built, not scaffolded):
- Any tool for the helper: reading pages, acting, terminals (parts 2 and 3). It is started with no
  tools at all.
- Generative UI in the chat. The owner chose a TSX page partly for this; when it comes, generated
  UI is untrusted and renders in a locked frame with no access to the plugin's bridge.
- A list of past conversations, several conversations at once, attachments, voice.
- The panel in little windows. A second plugin with a panel (the frame allows it, nothing is built
  for choosing between two beyond a plain menu).
- A second provider (Codex or others); see section 4 for what part 1 does so that one fits later.
- Browser abilities or network destinations for plugins in general (`permissions.network` stays
  empty). An API key field in Singularity.
- Starting, watching or assigning terminal agents.

**Anti-goals: it fails even if it works when…**
- Singularity shows a Claude login, or reads, stores or forwards a Claude token or API key.
- The core gets AI in it: every model call lives in the plugin's folder, and removing the plugin
  leaves no AI in the app.
- The helper can run shell commands or edit files in part 1.
- The plugin's page can reach the internet or another site's data.

## Constraints

- `CLAUDE.md`: Swift + SwiftUI, WKWebView only, no new app dependency without asking, no telemetry.
- **Anthropic's rules, as read on 2026-11-13.** The Help Center article "Use the Claude Agent SDK
  with your Claude plan" (updated 2026-10-07) says Agent SDK, `claude -p` and third-party app usage
  draw from the subscription's limits. The Agent SDK overview says third-party developers may not
  "offer claude.ai login or rate limits" unless approved. So: Singularity never performs or shows a
  login and never touches a token; it runs the user's own installed, already signed-in Claude Code.
  This moved three times in 2026 (ban in February, a separate-credit plan in May, its pause in
  June). If it moves again the chat must fail with a clear message, not silently bill something.
- The SDK overview's branding rule: "Claude Code" may not appear in a product's name or interface.
  The plugin is named "Assistant"; where the provider is named, it is "Claude". The pinned path on
  the approval sheet is the one place the program's own name shows.
- "Agent" stays the app's word for outside agents (Settings → Agents, the agent inbox, "Let agents
  use this Space"). No new string calls the Assistant an agent.
- Plugins stay reviewable: plain source, pinned packages, an approval sheet in plain words.

## Approaches

- **A. Plugin all the way.** The plugin API carries everything, including browser and terminal
  abilities for plugins. Anyone could write another helper; but it is the biggest build and a
  second route to the browser beside MCP, with its own copy of the policy checks.
- **B. Plugin as the face, the agent door as the hands. (Chosen by the owner.)** The plugin API
  gains only a surface and one running program. In part 2 the Agent SDK is pointed at
  `singularity-mcp`, so the helper is one more agent: same tools, policy, approvals, log.
- **C. Built into the app.** Least work, but puts AI in the core. Dropped.

Decided by the owner on the way: the panel's contents are a **TSX page the plugin ships, in a native
frame** ("easier to support generative UI in chat this way"). Recorded here as the reading of
`CLAUDE.md`'s "no web-based app chrome": the frame is native; the page is the plugin's content.

## As spiked (2026-11-13, throwaway script, nothing kept)

- Agent SDK `@anthropic-ai/claude-agent-sdk` 0.3.323 runs on the bundled Bun 1.4.4.
- With a clean environment (`HOME`, `USER`, `PATH`, `TMPDIR` only) and
  `pathToClaudeCodeExecutable` set to the installed `claude` (2.1.323), it used the existing
  sign-in: `apiKeySource: "none"`. First text after about 1.2 s.
- `spawnClaudeCodeProcess` got `command`, `args`, `env` and needs back only stdin, stdout, exit and
  kill. The arguments were `--output-format stream-json --verbose --input-format stream-json
  --max-turns=3 --permission-prompt-tool=stdio --tools= --setting-sources=
  --include-partial-messages`. So the app can start the program and carry the two streams.
- `tools: []` left no built-in tool; an in-process tool was called through `canUseTool`.
- It works with the SDK's own copy of Claude Code (329 MB, an optional package) deleted. What is
  left is 61 MB in about 100 packages.
- Not spiked: the SDK inside the plugin sandbox (it could not start a program there, which is the
  point of the bridge; whether it needs anything else the sandbox denies is the builder's first
  check).
- Seen on the owner's Mac: `claude` is a shell function that picks between two config folders
  (`~/.claude`, `~/.claude-gwb`). Programs are started by path, never through a shell, so the
  function does not apply; see "Which account".
- Without a model named, Claude Code picked its default (Fable 5.2); a two-turn "hello" was
  reported at $0.74 to $0.92 of notional cost. On a subscription that is usage against the plan's
  limits, so the model must be visible and choosable.

## 1. A plugin's own page

**Manifest.** A new top-level key **(my call on the shape)**:

```json
"panel": { "page": "panel.tsx", "title": "Assistant" }
```

`page` is a regular file in the folder, like `background`. No new permission key: having `panel` is
the permission, and the approval sheet gets the line "Shows its own panel and tab". The page and
every file it loads are in the fingerprint like all other files.

**Loading.** The page is served from the plugin's folder under the plugin's own origin by a
`WKURLSchemeHandler` (new in the app; e.g. `singularity-plugin://<id>/`), not by the artifact
server: no port, no token, no Space. `.ts/.tsx` files are compiled the way TS/TSX artifacts are
(`transpile-artifact.ts` in the sandbox, one file in, one module out, imports left as written), a
script opened as the page gets the same kind of shell page, and bare imports resolve through an
import map the app builds from the plugin's declared packages. Only files that are in the approved
fingerprint are served.

**Locked.** The page's web view has its own non-persistent data store. Every response carries a
Content-Security-Policy that allows only the plugin's own origin (no network, no inline script, no
`eval`); navigation away from the origin, new windows and downloads are refused; camera and
microphone are refused. It gets none of the page agent, capture or other plugins' scripts, and no
agent tool can list or read it.

**Talking to the background.** The page gets a small `singularity` global, checked by origin like
`ArtifactBridge`: `send(payload)` (answered by the background's existing `onPageMessage`, with
`tabID` and `frameHost` marking it as the plugin's own page) and `onMessage(handler)` for messages
the background pushes with a new `singularity.panel.post(payload)`. Pushes are how text streams in;
they are dropped when no page is open. Same size limit as today (256 KB a message).

**UI library (my call).** The Assistant plugin's page uses Preact, as a pinned plugin package: it loads
as plain ES module files with no bundling step, which React's packages do not. It is a plugin
package, not an app dependency; the owner may prefer otherwise.

## 2. The frame: right-hand panel and tab

**Panel.** A native column at the right edge of the main window, beside the content area (splits
included), with a draggable left edge. Width is remembered in `settings.json` with limits like the
sidebar's. It belongs to the window, not to a Space: it stays through tab and Space switches. A
header row has the plugin's title and a menu: Open as Tab, Close. (New Chat is a button inside the
plugin's page; plugins do not add native menu items.) Shown and hidden from the View menu, the palette and a shortcut **(my call: ⌃⌘J; the
builder checks it is free)**. Hidden while the welcome flow covers the window. None in little
windows.

**Tab.** A new tab kind, `TabKind.plugin(id:)`, so this passes the scope rule as a tab type. It sits
in the sidebar like any tab, can be pinned, moved to folders and put in a split, and is saved in
`space.json`.

**When the plugin isn't running (my call).** The plugin's page is served only while its background
runs. Otherwise the panel and the tab show a native "this plugin isn't running" page with the
reason the app already has (`PluginScan`'s status text: not approved, changed since approval,
program not found, stopped after crashes) and a button to Settings → Plugins; the page comes back
when the plugin does. So the plugin's page never has to explain a state in which its background
does not exist.

**Space switches (my call).** Today a plugin's background starts only when the plugin is on in at
least one Space, and messages from a Space where it is off are dropped. A panel belongs to no
Space, so: a plugin with a `panel` runs whenever it is approved, and messages from its own page are
never dropped for a Space reason. The per-Space switches keep meaning what they mean today, "its
page script runs in this Space", and are not shown for a plugin that has no page script. Web-only commands (Find, Reload,
Zoom, Print, address row) are off for it.

**One page, one place (my call).** A plugin has one page view. "Open as Tab" moves it into a new tab
in the selected Space and closes the panel; "Move to Side Panel" (the tab's context menu and the
palette) moves it back and removes the tab. Opening the panel while the page is a tab selects that
tab. So there is exactly one conversation on screen, never two copies to keep in step. Closing the
tab or the panel hides the page; the plugin's background and its conversation go on.

## 3. A running program

**Manifest.** A new permission **(my call on the shape)**:

```json
"permissions": { "programs": ["claude"] }
```

Names follow the rules of `commands`: resolved to a path through the login shell's PATH at
approval, shown and pinned, the refused-names list applies, a changed path asks again. The approval
sheet says: "Keeps <path> running and talks to it. This program is not sandboxed: it uses the
internet and acts as you."

**API (background).** `singularity.spawn(program, args, options?)` returns an object with
Node-style `stdin` and `stdout` streams, `kill(signal)`, `exitCode`, `killed` and `exit`/`error`
events: the shape the SDK's `spawnClaudeCodeProcess` asks for. Over the wire that is five new
`PluginWire` messages (start, input, output, exit, kill). Output is carried as it arrives; when the
plugin reads slowly the app stops reading the program (no unbounded buffer). stderr goes to the
plugin's log.

**Rules.**
- At most one running program per plugin in part 1; a second `spawn` is refused.
- The program ends when the plugin stops, is paused, is removed, or the app quits (SIGTERM, then
  SIGKILL after a short wait), together with what it started.
- Working directory: the plugin's data folder.
- **The app builds the environment, not the plugin:** the user's real `HOME`, `USER`, the login
  shell's `PATH`, `TMPDIR`, `LANG`, and `CLAUDE_AGENT_SDK_CLIENT_APP=singularity/<version>`. From
  what the plugin passes, only names listed in the manifest's `programEnv` are taken **(my call)**;
  the Assistant plugin lists `CLAUDE_CONFIG_DIR` and the SDK's own three (`CLAUDE_AGENT_SDK_VERSION`,
  `CLAUDE_CODE_ENTRYPOINT`, `CLAUDE_CODE_SDK_READS_SESSION_STATE`). The approval sheet lists them.
  Nothing else from the app's own environment is inherited.
- Arguments are free, as further arguments of `commands` are. See "Known weaknesses".
- **Test and development copies (my call).** A copy started with `SINGULARITY_HOME` refuses every
  `spawn` ("programs are off in a test copy"), like Connect and updates: with the real `HOME` it
  would chat on the owner's account, use their plan and write sessions into their real Claude
  folder. The one way in is the environment switch `SINGULARITY_REAL_PROGRAMS=1`, set by hand for
  the owner's hands-on checks and the opt-in real test; never set by a script or a test run.

**Packages.** The SDK is a declared, pinned plugin package, installed at approval as packages are
today. The install must leave out optional packages, or it pulls a 329 MB copy of Claude Code that
is never used; the builder checks how `PluginPackages` does that with `--frozen-lockfile`.

## 4. The Assistant plugin (`Plugins/assistant/`, shipped in the app)

- **Other providers later (owner's wish; not built in part 1).** `background.ts` keeps everything
  that knows about Claude in one file behind a small interface the rest of the plugin uses: start
  or resume a conversation, send a message, stop, and a stream of events (text, done, error, how
  it is signed in, models). A second provider (for example Codex through its own installed
  program) is then one more such file plus one more name in `programs`, which asks for approval
  again. Part 1 ships no provider picker, no second file and no placeholder for one. The page's
  texts name the provider only where it matters (sign-in help, billing, model).
- `plugin.json`: `panel`, `background`, `permissions.programs: ["claude"]`, the package list. No
  page script, no sites, no commands, no network.
- `background.ts`: one SDK `query` in streaming-input mode, with `tools: []` (no shell, no file
  tools), `settingSources: []` (none of the user's hooks, plugins or MCP servers), no MCP servers,
  partial messages on, and `spawnClaudeCodeProcess` wired to `singularity.spawn`. It forwards text
  deltas and the end of each answer to the page, takes messages and Stop (the SDK's interrupt) from
  it, and keeps the session id and the chosen model in `singularity.storage`.
- `panel.tsx`: the conversation, an input box (Return sends, Shift-Return a new line), Stop while
  an answer streams, New Chat, and the model's name as a menu of the models Claude Code reports
  **(my call)**. Answers are rendered as Markdown; HTML inside an answer is shown as text, never
  inserted.
- **Continuing after a restart (my call).** Two things are needed and they live in two places.
  *What Claude remembers:* the plugin resumes the last session by its id; that session is Claude
  Code's own file in its config folder, which the plugin's sandbox cannot read and does not need
  to. *What the owner sees:* the plugin keeps its own copy of the current conversation's visible
  messages as a file in its data folder (under `~/Singularity/`), written as messages arrive and
  deleted by New Chat. No sandbox allowance is added. Claude Code's session files are a third
  known exception to "everything under `~/Singularity/`", to be written into `CLAUDE.md`. If the
  session can no longer be resumed, the page shows the old messages greyed out and starts a new
  session, saying so.
- **Which account (my call).** By default Claude Code's default config folder. The plugin's own
  page has a small settings view with one field, "Claude config folder", for people who keep
  several accounts apart with `CLAUDE_CONFIG_DIR`; empty means the default. The value is kept in
  `singularity.storage` and passed through `programEnv`. Nothing provider-specific is added to the
  app's Settings window, and there is no general plugin-settings mechanism in part 1.
- **Subscription or API key (my call).** The chat uses whatever the installed Claude Code is signed
  in with: a Claude plan, or a Console account billed by API. A user who wants API billing signs
  Claude Code in that way. Singularity has no key field and stores no key. The owner asked for "own
  subscription or API key"; if a key field inside Singularity is wanted after all, that is a change
  to this design.
- **What it bills is always visible (my call).** Claude Code reports how it is signed in when a
  session starts (`apiKeySource`). The page shows it beside the model: "Claude plan" or "API
  billing". The first time it is API billing, and whenever it changes from one to the other, the
  page says so once before the next message is sent. It refuses nothing; other failures are
  Claude Code's own errors, shown as they come. This is all that "fail with a clear message, not
  silently bill something" asks for.
- **States the page must show, in plain words** (all with the background running): not signed in
  (run `claude` in a terminal tab and sign in); limit reached; program ended unexpectedly (with a
  Try Again button); programs off in a test copy.
- The README and the approval sheet say that the chat counts against the user's Claude plan.

## 5. Safety

- Everything Claude writes is untrusted text in the page: rendered, never run.
- With no tools, the worst a poisoned answer can do in part 1 is show misleading text.
- The page cannot reach the network or other origins (section 1); its bridge accepts only its own
  origin.
- The program is the user's own Claude Code with the user's powers. What keeps part 1 harmless is
  the reviewed `background.ts` starting it with no tools; the app does not enforce that.

**Known weaknesses, accepted and to be written into the plugin guide's review checklist:**
- A plugin granted a program can pass it any arguments. For `claude` that includes switching every
  tool on and skipping permission prompts, which is the power to run anything as the user. A
  reviewer must read how `spawn` is called; the approval sheet's wording says the program acts as
  you. The app could pin the arguments for known programs later; not in part 1.
- About 100 transitive packages (61 MB) come with the SDK. They are pinned and fingerprinted, but
  nobody reads them. This stretches "a person can review a plugin in a few minutes" to "a person
  can review the plugin's own files".
- The SDK and the installed Claude Code are released together (0.3.323 with 2.1.323). The plugin
  pins the SDK while the user's Claude Code updates itself; a mismatch may break the chat. The page
  shows both versions in its error state.

## 6. Documents

- `CLAUDE.md`: scope-change lines for the Assistant (parts 1 to 3, with the owner's decisions:
  approach B, TSX in a native frame, type-into-terminals only with approval, lifting "no agent
  orchestration" for the helper only in part 3), `TabKind.plugin`, the new plugin abilities, the
  session-transcript exception.
- `docs/plugins/AUTHORING.md`: `panel`, the page API, `programs`, `spawn`, the new review items.
- `IDEAS.md`: the Claude Chat item points here; parts 2 and 3 listed as next.
- The plugins design's round 2 section: a note that network destinations were not needed.

## 7. Tests

- Core (Swift Testing): manifest decoding and validation of `panel`, `programs`, `programEnv`;
  approval text; the environment rule; the new wire messages; `TabKind.plugin` in `space.json`
  (old files still load); the one-page-one-place rules as pure functions.
- App tests (off-screen, never key): the scheme handler serves only fingerprinted files, compiles
  TSX and sends the policy header; a page cannot fetch a fixture site; page ↔ background messages
  against a fake background; `spawn` against a small fixture program (echo, slow reader, exit,
  kill on plugin stop), which test copies allow because the fixture is passed in, not resolved
  from a manifest; `spawn` refused under `SINGULARITY_HOME`; a panel plugin launching with no
  Space switched on; the native "isn't running" page; panel ↔ tab moves with a real `AppState`.
- Bun tests for the plugin's own logic with a fake `singularity`.
- **Never in tests or trials: the real `claude`.** Tests use the fixture program. One opt-in manual
  check, like `RealAgentConnectTests`, sends one message with the real one. A throwaway
  `CLAUDE_CONFIG_DIR` cannot be used for it (that folder would be signed out), so it runs on the
  owner's account, by the owner's choice, with `SINGULARITY_REAL_PROGRAMS=1`.
- By the owner's hands: the panel's feel, streaming, Stop, Open as Tab and back, restart, a signed
  out Claude Code.

## Left to the builder

The exact API and wire names; the scheme's name; how the import map is built; the Markdown
renderer (own small one or a pinned package); the panel's width limits and look within the app's
existing style; the shortcut if ⌃⌘J is taken; how the sandbox check of the SDK turns out and what
the smallest fix is if it needs one more allowance (ask the owner before widening the sandbox).
