# Agent inbox: design

Status: **built on 2026-11-12** (branch `inbox`, not merged yet). Lines marked *(builder's call)*
were decided by the writer, not the owner, and are open to review. "As tested" and "As built" at
the end override the design where they differ.

## Intent: why

The owner runs coding agents in terminal tabs in several Spaces and works somewhere else in the
meantime. When an agent stops to ask something, or finishes, nothing reaches him: he was "in
another Space, working on something else", missed the ping and found out later. The same happens
with the browser's own approval sheet when Singularity is not in front: nobody notices, and after
two minutes the request is denied.

The inbox is one place, reachable from every Space, that says which agents are waiting for him
or have finished, lets him answer what can be answered right there, and takes him to the tab.

This is not agent orchestration (CLAUDE.md keeps that out of scope): the inbox starts nothing,
assigns nothing and keeps no history. It only shows what the hosted terminals and the browser's
own approval step report.

## Goals

1. From any Space, see every agent that is **waiting** or **done**, in all Spaces.
2. Be told when one arrives: a count on the Space rail and a macOS notification.
3. Answer a Claude Code **question** (its `AskUserQuestion` tool) and a Claude Code
   **permission request** in the inbox, without going to the terminal.
4. Answer the browser's own **approval requests** (agent tool calls and
   `window.singularity.prompt()`) in the inbox. The inbox **replaces** the approval sheet.
5. Jump from any entry to its tab, switching Space when needed.
6. Agents other than Claude Code (the owner also runs Hermes) work with no setup at a basic
   level: they appear as waiting or done, with a jump to the terminal.

## Non-goals

- A history of past entries. An entry is gone once it is handled.
- Typing free text to an agent from the inbox. "Other…" on a question goes to the terminal.
- Saving anything to disk. The inbox is rebuilt from what the terminals report while the app runs.
- Entries for agents that are working. They are only a quiet count ("2 more agents working").
- A sound of our own. The macOS notification follows the system's settings.
- Starting, stopping or instructing agents. Showing terminals Singularity does not host.
- Per-agent integrations beyond Claude Code. Everything else gets the basic level.
- A state mark on terminal tab rows in the sidebar *(builder's call: left out; could follow)*.

## Anti-goals

- **Getting in the way of the terminal.** If the owner is looking at an agent's terminal, the
  question must appear there exactly as today, at once. The hook must never make Claude Code
  slower or stranger outside Singularity, or when Singularity is not running.
- **A weaker approval step.** Replacing the sheet must not loosen anything in
  `AgentApprovalRules`: same decisions, same "always ask" cases, same timeout meaning "no",
  same log lines.
- **Trusting agent text.** Everything an agent or page puts in an entry is untrusted: shown as
  plain text, never as markup, never acted on.

## What the owner sees

Mockup the owner chose (option A): `.superpowers/brainstorm/…/content/inbox-placement.html`
(not committed; described here in full).

**The rail.** At the top of the Space rail, above the Space circles, a tray button. It carries a
red count of all entries. Each Space circle carries its own small count of that Space's entries.
No entries: no counts, the button stays, dimmed.

**The list.** Clicking the tray opens a panel (about 330 pt wide) anchored to the button, over
the sidebar and page. It does not block the window. Header: "Inbox" and, when any agent is
working, "N more agents working". Then one card per entry:

- First line: Space colour dot, agent name ("Claude Code", "Hermes", "Codex", or the program's
  name), Space name and folder (for terminals) or site and tab title (for browser approvals), and
  a state chip: `asks`, `permission`, `waiting`, `done · 4 min`, or for browser approvals the
  time left.
- Body, by kind:
  - **Question** (Claude Code, hook installed): the question text and one button per option.
    With one single-choice question, clicking an option answers at once. With several questions
    or multiple choice, options are toggles and a "Send" button answers. An "Other…" button goes
    to the terminal, where the question then appears.
  - **Permission** (Claude Code, hook installed): what it wants to run or change (tool name and
    its input, long input in a scrolling monospaced box like the approval sheet has today),
    with Allow and Deny. Allow means this one time only.
  - **Browser approval**: what the sheet shows today: "<agent> wants to <action>", the
    element or URL, Space and tab, the text being sent if any; buttons Allow, Allow on <site>
    (when the rules offer it), Deny, and Show Tab.
  - **Waiting** (basic level): the agent's own short message if it sent one, else "Waiting for
    you".
  - **Done**: the agent's last message, shortened, if known; a Dismiss button.
- Every card has "Go to terminal" (or "Show Tab"): selects the Space and the tab. For a held
  question or permission this hands it back to the terminal (see below).

Order *(builder's call)*: browser approvals (they have a deadline) first, then questions and
permissions, then waiting, then done; oldest first within each group.

**Arrival.**
- An entry is **not** created, and nothing is sent, when the owner is looking at that terminal:
  the tab is on screen (selected, or in the visible split) in the frontmost Singularity window
  while Singularity is the active app.
- Otherwise the counts update and a macOS notification is posted: title "<agent> · <Space>",
  body the question or message, shortened. Clicking it brings Singularity forward and opens the
  inbox (not the terminal). The notification is withdrawn when its entry goes away.
- A browser approval arriving while Singularity is active opens the inbox by itself with that
  entry on top, so it is as hard to miss as the sheet was; no notification in that case. When
  Singularity is not active: notification, plus the Dock bounce the sheet does today.
- The Dock icon shows the same count as the tray *(builder's call)*.
- **Keyboard and the self-opening panel** *(builder's call, on the careful side)*: when the
  inbox opens by itself it does not take keyboard focus, and no button in the inbox is ever a
  default button: Return or Space typed into a page or terminal can never press Allow. Buttons
  are pressed with the mouse, or with the keyboard only after the owner opened the inbox
  himself (shortcut or click) and moved to a button.

**Leaving.** An entry goes away when:
- it is answered or dismissed in the inbox;
- the owner **goes to** its terminal, answered or not. *(builder's call on what that means:)*
  the tab comes on screen because he selected it, its split or its Space ("Go to terminal"
  included), or he clicks or types in that terminal. Singularity merely becoming the active app
  is **not** enough: when he comes back from another app, or clicks the notification, and the
  agent's tab happens to be the one showing, the entry must still be there to read. So
  "looking" is checked once when something arrives (to decide whether to make an entry), and
  after that only these deliberate actions remove it;
- the agent moves on (reports working again, or its program exits, or the tab closes);
- for browser approvals only: it is answered or its time runs out. Looking at the tab does not
  remove it; Show Tab restarts its time, as today.

**Getting there** *(builder's call)*: a menu item and command palette entry "Show Inbox" with a
keyboard shortcut the builder picks from the free ones. Esc closes the panel and answers nothing
(with the sheet, Esc meant Deny).

**Notification permission.** macOS asks once whether Singularity may send notifications; ask the
first time an entry would have sent one, not at launch *(builder's call)*. Refused: everything
else still works.

## How the app learns about agents

### Level 1, any agent, no setup

Three things a program in a terminal can send, all already parsed by SwiftTerm (verify the exact
delegate API in the pinned SwiftTerm before use):

1. **Program status (OSC 7501).** SwiftTerm hands over records with `state` (idle, working,
   done, blocked, error), `kind` when blocked (permission, question, auth), `app`, `title`,
   `message`. Claude Code 2.1.295+ sends it (the owner has 2.1.322). Mapping: blocked → a
   waiting entry (chip from `kind`), done → a done entry, error → a waiting entry with the
   message, working → remove the tab's entry and count it as working, idle → remove.
2. **Terminal notification (OSC 777, and OSC 9 if SwiftTerm exposes it).** → a waiting entry
   with the notification's text.
3. **Bell.** → a waiting entry "wants attention", only when a program other than the shell is in
   the foreground (so a beep at the prompt does nothing).

A tab has at most one level-1 entry. A program that sends status records is trusted over bell
and notification from the same tab, so there are no doubles. (Held questions and permissions
from level 2 are separate entries, one per request; see there.)

**"Done" means "finished its turn".** Claude Code reports done at the end of every turn,
including a turn that ends by asking something in plain text. That is wanted: both are "it's
your move", and the owner asked to be told. The done entry shows the last message so a closing
question can be read in the inbox. No minimum turn length, no guessing whether the message is a
question *(builder's call)*. SwiftTerm's note applies: strip
direction overrides and invisible formatting characters from this text before showing it.

The agent's name comes from the status record's `app`, else from the foreground program
(`claude` → Claude Code, `codex` → Codex, `hermes` → Hermes, else the program name).

Hermes Agent 0.22.5 is installed on the owner's Mac (`~/.local/bin/hermes`). What it sends is
not known yet; the builder checks and writes down the result. Whatever it sends through the
three routes above works; nothing Hermes-specific is built.

### Level 2, Claude Code with the Singularity hook

Claude Code hooks (documented at code.claude.com/docs/en/hooks) give what level 1 cannot: the
question itself, and a way to answer.

**Which hooks.**
- `PreToolUse`, matcher `AskUserQuestion`: receives `tool_input.questions`. Answering =
  returning `permissionDecision: "allow"` with `updatedInput` that repeats `questions` and adds
  `answers` (question text → chosen label; several labels joined with commas).
- `PermissionRequest`: receives `tool_name`, `tool_input`. Answering = `decision.behavior`
  `allow` or `deny`. Never send `updatedPermissions`: Allow in the inbox is for this once.
- `Stop`: receives `last_assistant_message`, used as the text of the done entry. It never
  blocks.

**How a hook reaches the app.** A command hook that runs a small helper inside the app bundle
*(builder's call: its own tiny executable next to `singularity-mcp`, e.g.
`Contents/MacOS/singularity-hook`; a mode of `singularity-mcp` is also fine)*. The helper:

- reads two variables that terminal tabs export, next to `SINGULARITY_SPACE`: the tab's id and
  the path of the app's hook socket (so a test copy with its own `SINGULARITY_HOME` talks to
  itself). Both are also passed through `hc run` for herdr-core terminals. A herdr shell started
  before this feature has neither and stays at level 1 until the tab is reopened;
- **without those variables, or when the socket does not answer quickly, exits 0 with no output
  at once.** That is Claude Code running in some other terminal, or Singularity not running: the
  hook must be invisible there. It never starts the app;
- otherwise sends the hook's JSON plus the tab id to the app over a Unix socket under
  `~/Singularity/.run/` (same rules as the MCP socket: folder 0700, socket 0600, same uid only)
  and waits for the app's reply, which it prints as the hook's output.

**What the app does with a question or permission hook.**
- Owner is looking at that terminal: reply "no decision" at once. Claude Code shows its normal
  prompt in the terminal.
- Otherwise: create the entry and **hold** the hook. Then:
  - answered in the inbox → reply with the answer; the entry goes;
  - "Go to terminal", "Other…", or the owner looks at the terminal → reply "no decision"; the
    prompt appears in the terminal; the entry goes;
  - the hold limit is reached → reply "no decision" so the prompt appears in the terminal; the
    entry stays as a plain waiting entry. The limit must be safely below the hook's own
    `timeout`, which the installer sets explicitly. *(builder's call after the live test:
    the values; aim for a long hold, e.g. an hour, if Claude Code allows it.)*
  - the helper's connection drops (Claude Code was interrupted or quit) → the entry goes.
- While a hook is held, status records from the same tab must not replace the richer entry:
  a tab's level-1 entry is hidden while it has any held request.
- **Several at once** *(builder's call)*: Claude Code can raise several permission requests
  together (parallel tool calls, subagents), and one tab can hold more than one session. Each
  held hook is its own entry, keyed by its connection (with `session_id` and `tool_use_id` where
  given), each answered on its own. Going to the terminal hands all of that tab's held requests
  back. Nothing is ever dropped: a request the app cannot hold gets "no decision" and appears
  in the terminal.

**Installing the hook.** Owner decision: Singularity may write the hook into
`~/.claude/settings.json` when he presses a button, and take it out again. This is the one
exception to "agent config files are only read" (`AgentConnect`).

- Settings → Agents, on the Claude Code row *(needs the Connect work on the `onboarding`
  branch)*: "Show questions in the inbox" with Install / Remove, and Update when the installed
  hook points at another copy of the app (same idea as the Connect row's states).
- The edit is a pure function in Core, tested: settings text in, settings text out. It adds or
  removes only our three hook entries (recognised by the helper's path), keeps everything else,
  and refuses to touch a file that is not valid JSON (say so in the row). Write atomically.
  Key order and spacing of the file may change when it is rewritten; say that next to the
  button *(builder's call; if the builder finds that a Claude Code plugin installed through
  `claude plugin …` can carry the same hooks reliably, bring that to the owner as an
  alternative, don't switch silently)*.
- No file: create it with only the hooks. Translocated app (see `AgentConnect.isTranslocated`):
  no button.

### Browser approvals

`AgentApprovals.check` and `AgentApprovalRules` keep deciding exactly as today. Only `ask`
changes: instead of an `NSAlert` sheet it creates an inbox entry and waits for the answer or the
timeout (`agentApprovalTimeoutSeconds`, unanswered = denied, logged as `timeout`).

- Several requests can now wait at once (the sheet showed one at a time); each has its own
  deadline, shown on its card.
- "Allow on <site>" keeps its meaning. When it is pressed, other waiting requests for that
  site in that Space that the rules would now let through may be released too
  *(builder's call: only if `AgentApprovalRules.decide` says allow for them; never for the
  always-ask cases)*.
- `window.singularity.prompt()` goes through the same path and shows the text to be pasted.
- The agent log and the Agent activity pane are unchanged.
- The app test for the approval sheet is rewritten against the inbox entry.

## Where the code goes

Following the existing split (pure logic in Core with unit tests, AppKit/SwiftUI in the app):

- `SingularityCore/Inbox/`: the entry model and the rules as pure functions: what a status
  record, bell, notification or hook message does to the list; the "is the owner looking at it"
  decision given plain facts; ordering; counts per Space; text clean-up; building hook replies
  (`answers`, allow/deny, no decision) and parsing hook input; the settings.json edit.
- `Singularity/Inbox/`: the inbox object owned by `AppState` (single source of truth, like the
  rest), the hook socket listener, the notification centre wrapper, the rail button and panel.
- `TerminalSession`: forwards SwiftTerm's status, bell and notification callbacks; exports the
  two variables.
- `AgentApprovals`: `ask` goes through the inbox.
- The hook helper: no logic beyond relaying, like `singularity-mcp`.
- `scripts/build-app.sh` / `release.sh`: build, copy and sign the helper.
- No new dependency. `UserNotifications` is a system framework.

## Order of work

1. **Live test first (throwaway).** Everything in level 2 is from documentation only. Before any
   product code, confirm with the owner's Claude Code:
   - `PreToolUse` for `AskUserQuestion` receives the questions and options;
   - returning `allow` + `answers` answers it, for one and several questions and multiple choice;
   - returning nothing shows the normal prompt, also after the hook was held for a while;
   - how long a hook may be held, and what Claude Code does when a hook times out;
   - the same for `PermissionRequest`;
   - which status records Claude Code sends, and when (so the mapping above is right);
   - what Hermes sends.
   If answering does not work as documented, stop and bring it to the owner: the fallback is
   showing the question read-only with "Go to terminal".
2. Level 1 and the inbox itself (rail button, panel, counts, notification, jump, leaving rules).
3. Browser approvals moved from the sheet into the inbox.
4. The hook helper, the socket, held questions and permissions.
5. The installer in Settings → Agents. This step needs the `onboarding` branch merged; the
   `inbox` branch was cut from `main` and should be rebased onto it then.
6. CLAUDE.md: architecture entries, the settings.json exception, and a line under the scope
   changes.

## Testing

- Core unit tests for every rule above, including: an entry is not created while looked at; a
  held question is not replaced by a status record; the settings edit round-trips a file with
  other hooks and settings in it and removes cleanly; damaged settings are refused.
- App tests (off-screen window, nested in `AppTests`): a browser approval becomes an entry and
  Allow / Deny / timeout give the same outcomes and log values as the sheet did.
- By hand, in a second copy (`SINGULARITY_HOME=/private/tmp/sg-test`, full bundle in
  `/private/tmp/sg-app` so the helper exists): a real Claude Code question answered from another
  Space; the same question with the terminal in view; Claude Code in Terminal.app with the hook
  installed and Singularity closed (must behave as if no hook existed).
- Never install the hook into the owner's real `~/.claude/settings.json` from a test; the
  installer takes the file path as a parameter.

## Decisions the owner made

- Reach: a count on the sidebar's Space rail and a macOS notification.
- Placement: tray button on the Space rail opening a list (mockup A), not a sidebar pane.
- Entries: agents waiting or done; questions shown and answerable; jump to the terminal.
- An entry leaves when answered or when its terminal is looked at; no history.
- Claude Code first, Hermes sometimes: full level for Claude Code, basic for the rest.
- Singularity may write its hook into `~/.claude/settings.json` behind a button.
- Browser approvals are included, and the inbox replaces the sheet.
- Accepted as proposed: permission requests answerable in the inbox; working agents only a
  count; nothing sent while the terminal is in view; the notification opens the inbox.

## As tested (2026-11-12)

Live test with the owner's Claude Code 2.1.322 (`--model haiku --permission-mode default`) in a
scratch project whose `.claude/settings.json` held the hooks (`PreToolUse` matcher
`AskUserQuestion`, `PermissionRequest`, `Stop`, `Notification`). Claude Code ran in a detached
tmux pane behind a small pty recorder, with the env a Singularity tab sets (`TERM=xterm-256color`,
`TERM_PROGRAM=Singularity`, `COLORTERM=truecolor`, `SINGULARITY_SPACE`, and
`SINGULARITY_TAB=test`). The owner's own user-level hooks (nodeterm, herdr, rex) also ran and did
nothing. This section overrides anything above that it contradicts.

### Differs from the design

1. **`PermissionRequest` runs alongside the terminal's dialog, not before it.** The dialog is on
   screen while the hook is held, and whichever answers first wins. Answering in the terminal
   with Esc kills the hook (SIGTERM) at once; answering **Yes in the terminal does not**: the hook
   keeps running until its own timeout. So the app must release a held permission when the tab
   moves on (status record `working`/`done`/`idle`, or `Stop`), or the helper lingers up to an
   hour. "Go to terminal" needs no hand-back for permissions: the prompt is already there.
2. **`AskUserQuestion` also raises `PermissionRequest`** (`tool_name: "AskUserQuestion"`, same
   `tool_input.questions`) whenever `PreToolUse` gave no decision: after a "no decision" reply,
   after the hold, after a hook timeout. Not after `allow`. Its dialog is the question itself, on
   screen at the same time. The app must not show it as a permission entry: reply "no decision"
   at once. (Answering it also works, see item 5 below; not used by the design.)
3. **`PermissionRequest` stdin has no `tool_use_id`.** `PreToolUse` has one. Key held
   permissions by connection (plus `session_id`).
4. **Status records (OSC 7501) only after a probe reply.** At start Claude Code sends
   `ESC ] 7501 ; ? BEL` and waits up to about 2 s; only if the terminal answers
   `ESC ] 7501 ; ? BEL` (or `ST`) does it send records, otherwise never. `TERM_PROGRAM` plays no
   part. SwiftTerm 1.99.3 answers the probe itself (`ProgramStatus.swift`), so the built-in
   terminal is fine; whether the probe survives `hc attach` (herdr-core terminals) was not tested.
5. **The text in status records is base64.** `msg` (and `title`) are base64 UTF-8; fields are
   `key=value` joined with `:`. The `done` message is a short model-written summary
   ("user picked Postgres as the database"), not the last message: use `Stop`'s
   `last_assistant_message` for the done entry's text.
6. **While a `PreToolUse` hook is held the status is `working`** (with `msg` = the question
   text), not `blocked`; the terminal shows a spinner "running PreToolUse hooks…" and no question.
   `blocked` comes when the `PermissionRequest` stage starts (same instant as that hook).
7. **Interrupt = no `Stop`.** Esc or Ctrl-C during a turn: held hooks get SIGTERM, status goes to
   `idle`, no `Stop` hook. A normal turn end (including after a deny) does run `Stop`.
8. **Hermes sends nothing by default** (see item 9).

### Per item

1. **`PreToolUse` stdin** (trimmed; `transcript_path`, `scratchpad_dir`, `prompt_id`, `effort`
   left out): `question`, `header`, `options[].label`, `options[].description` and `multiSelect`
   are all there; `tool_use_id`, `session_id`, `cwd` too.
   ```json
   {"session_id":"f32c0756-ce23-43ec-afd7-5708e5dd894e","cwd":"/private/tmp/…/hooktest",
    "permission_mode":"default","hook_event_name":"PreToolUse","tool_name":"AskUserQuestion",
    "tool_input":{"questions":[{"question":"Which database should we use?","header":"Database",
      "options":[{"label":"SQLite","description":"File-based, embedded database …"},
                 {"label":"Postgres","description":"Full client-server relational database …"}],
      "multiSelect":false}]},
    "tool_use_id":"toolu_0126uBQMDbQKLFvJr5ZscFJR"}
   ```
2. **Answering works** for one question, two questions, and multi-select; no prompt appears, the
   terminal shows "User answered Claude's questions: · <question> → <answer>". Reply that worked:
   ```json
   {"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow",
    "updatedInput":{"questions":[ …the questions exactly as received… ],
      "answers":{"Which database should we use?":"Postgres",
                 "Which features should we enable?":"Auth, Search, Billing"}}}}
   ```
   - `updatedInput` replaces the whole input: `questions` must be repeated. With `answers` only,
     the tool fails with "PreToolUse hook for AskUserQuestion returned updatedInput that failed
     schema validation … `questions` is missing" and the model sees the error.
   - **Multi-select: join labels with `", "` (comma and space)**: that is what Claude Code itself
     stores when the owner ticks several boxes in the terminal (`"Auth, Billing"`). The string is
     passed to the model verbatim (`","` arrived as `Auth,Search,Billing`), so `", "` it is.
3. **Empty stdout, exit 0** after 0 s, 5 s and 2 min: the normal question appears each time (after
   the hook returns, via the `PermissionRequest` stage, see difference 2). 15 min was not run:
   5 s and 2 min behaved the same, and item 4 shows what happens at the limit.
4. **Timeout.** `"timeout": 3600` is accepted without a word (the whole first session ran with
   it). The settings schema says only "positive number"; for command hooks 2.1.322 uses
   `timeout * 1000` with no cap. With `"timeout": 20` and a 40 s hook: at 20 s the hook gets
   SIGTERM, its later output is lost, nothing is shown in the terminal, and Claude Code carries on
   as if there were no decision (question: `PermissionRequest` stage, then the normal prompt;
   permission: the dialog that was already up stays).
5. **`PermissionRequest`**, Bash `rm …` (not pre-allowed; `touch` in the project folder was not
   always prompted). Stdin (trimmed):
   ```json
   {"session_id":"f32c0756-…","cwd":"/private/tmp/…/hooktest","permission_mode":"default",
    "hook_event_name":"PermissionRequest","tool_name":"Bash",
    "tool_input":{"command":"rm made-by-claude-1.txt","description":"Remove file made-by-claude-1.txt"},
    "permission_suggestions":[{"type":"addDirectories","directories":["/private/tmp/…/hooktest"],
      "destination":"session"},{"type":"setMode","mode":"acceptEdits","destination":"session"}]}
   ```
   - `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}`:
     runs; terminal shows "Allowed by PermissionRequest hook". Nothing is remembered (a later
     `rm` asked again).
   - `"behavior":"deny"`: not run; "Denied by PermissionRequest hook", the model is told
     "Permission denied by hook" and carries on with its turn. An optional
     `"message":"…"` replaces that reason (seen by the model and in the terminal); use e.g.
     "Denied in the Singularity inbox."
   - Empty reply: the dialog (already on screen) is answered in the terminal.
   - For `AskUserQuestion`: `allow` without `updatedInput` leaves the question to the terminal;
     `allow` with `"updatedInput":{"questions":[…],"answers":{…}}` answers it.
6. **`Stop`**: `last_assistant_message` is there.
   ```json
   {"session_id":"f32c0756-…","cwd":"/private/tmp/…/hooktest","permission_mode":"default",
    "hook_event_name":"Stop","stop_hook_active":false,
    "last_assistant_message":"You chose SQLite as the database. I haven't done anything else.",
    "background_tasks":[],"session_crons":[]}
   ```
7. **Killing Claude Code while a hook is held**: Esc, Ctrl-C (one press interrupts the turn) and
   closing the terminal (pty hang-up) all SIGTERM the hook at once; the question is recorded as
   declined. So the helper sees its process end / the app sees the socket drop.
8. **OSC 7501** (after the probe was answered; all `app=claude-code`, terminated with BEL):
   - start: `state=idle`;
   - prompt sent: `state=working`, then `working` with `msg` = what it is doing
     ("Removing file victim.txt", or the question text while a `PreToolUse` hook runs);
   - question: `state=blocked:kind=question:msg=answer: Which database should we use? (SQLite · Postgres)`;
   - permission: `state=blocked:kind=permission:msg=approve Bash: rm victim.txt`;
   - answered: `working`; turn end: `state=done`, about 1 s later `done` again with the summary
     `msg`; interrupted: `state=idle`;
   - the code also has `id=`, `title=`, `progress=` (subagents/tasks) and `state=clear[:id=]`.
   - No BEL, OSC 9 or OSC 777 from Claude Code. Its title (OSC 0) carries "✳ <topic>".
   - Without a probe reply (plain tmux): only the probe, no records.
9. **Hermes** 0.22.5: not run (it would need a model provider). From its source: no OSC 7501.
   It sends BEL + `OSC 9 ; Hermes: <text> BEL` when a blocking prompt opens
   (`display.bell_on_prompt`) or a turn ends (`display.bell_on_complete`); OSC 777 only in Warp.
   Both settings are **off** in the owner's `~/.hermes/config.yaml`, so by default Hermes sends
   nothing level 1 can see. Turning them on gives a waiting entry per prompt and per turn end.

**Also recorded for later tasks**
- `session_id` and `cwd` are in every hook's stdin; `tool_use_id` only in `PreToolUse`.
- Order for a question: `PreToolUse` → (no decision) `PermissionRequest` → dialog; a
  `Notification` hook (`notification_type: "permission_prompt"`, "Claude needs your permission")
  follows about 6 s after any question or permission dialog appears.
- The hook's environment is the terminal's: `SINGULARITY_TAB` and `SINGULARITY_SPACE` exported
  before starting `claude` arrive in the hook; Claude Code adds `CLAUDE_CODE_SESSION_ID`
  (= `session_id`), `CLAUDE_PROJECT_DIR`, `CLAUDE_PID`.
- Project-level hooks ran after the folder-trust prompt with no separate hooks prompt.
- SwiftTerm 1.99.3 (read in its source, Task 3): `registerOscHandler(code: 9)` would replace its
  own OSC 9 handling, which is what reads `9;4` progress reports, so the app reads OSC 9 and 777
  through `observeOscEvents` (a copy of every OSC sequence, built-in handling untouched) instead.

**The two numbers:** `hookTimeoutSeconds = 3600`, `holdLimitSeconds = 3300` (no cap found).

## As built (2026-11-12)

Built as designed, with the changes below. "Ruling" marks a decision taken while building that
the owner has not seen yet; each says what it costs if it is wrong. Everything on screen still
needs the owner's own look (no builder launched a copy of the app, see R2).

### Differs from the design

1. **Getting there.** The menu item and palette entry are "Show Inbox", shortcut ⌃⌘I. ⌃⌘I and
   the palette always show the inbox and give it the keyboard; a click on the tray toggles it.
   The panel never takes the keyboard while Singularity is not the active app.
2. **Chips.** A level-1 waiting entry shows `asks` or `permission` when Claude Code's status
   said so, else `waiting` (also for errors and sign-in prompts). `done` has no minutes in its
   first minute.
3. **Browser approvals got three safeguards** the sheet did not need, because several can now
   wait at once: see R12, R13, R14. Show Tab keeps the inbox open (the sheet also stayed up).
   When the inbox can't open (no window), an approval falls back to the banner and Dock bounce.
   An artifact's `prompt()` has no Show Tab, as before.
4. **The hook helper and the app talk a little more than designed:** the helper does not
   half-close its side (R15), the app checks that the request comes from a program inside that
   tab (R16), answers "got it" within 5 s (R17) and holds at most 5 requests per tab (R18). The
   helper always reads all of its input before exiting, even when it does nothing: otherwise
   Claude Code reports a hook error for large inputs.
5. **Hold limit and hook timeout:** 3300 s and 3600 s (`hookTimeoutSeconds`), as measured in the
   live test (no cap found).
6. **The Install row** is in Settings → Agents, under Claude Code in "Connect agents" (not in the
   welcome flow). Its button: Install, Remove, Update (the hooks point at another copy; the row
   shows that copy's path), or none. No button when the app runs translocated, when the file
   can't be read as JSON ("~/.claude/settings.json couldn't be read as JSON; it was left alone."),
   or for a bare debug binary, which has no helper inside an app bundle (the row says so).
   Errors from Install / Remove are shown in the row. The row reads the file when the Agents tab
   appears and after each press; it does not watch the file.
7. **How the file is written** *(builder's call)*: a file that is not valid UTF-8 counts as
   unreadable and is left alone. The new text goes to a temp file in the same folder, which then
   replaces the old one in one step. The file keeps its permissions; a new file gets 0600 (only
   the owner can read it; the owner's current file is 0644 and stays 0644), and a new
   `~/.claude/` folder 0700. A symlink (dotfile managers) is written through: its target changes,
   the link stays. Afterwards the file is read back and must say what was meant, or the row shows
   an error. Install on an installed file writes nothing; Remove with no file creates nothing.
   Rewriting sorts the keys and may respell some numbers (same values). The file's extended
   attributes are not carried over to the new file.
8. **Test copies can't touch the real file.** The row works on `SINGULARITY_CLAUDE_SETTINGS`
   when set, else on `<SINGULARITY_HOME>/claude-settings.json` when `SINGULARITY_HOME` is set,
   else on `~/.claude/settings.json`. The caption names the file in use.
9. **The Claude Code plugin alternative** (design: "bring that to the owner") was not looked
   into. It is in `IDEAS.md` under "New, not yet decided".
10. **herdr-core**: when `hc attach` ends but the shell lives on, the tab's entry stays (the agent
    may still be running in herdr).

### Rulings

- **R1. Questions keep only cleaned text.** The inbox shows each question and option after
  clean-up (control and invisible characters removed). The answer goes back to Claude Code in
  its original wording, found by cleaning the original again and matching. If two questions, or
  two options of one question, look the same after clean-up, the question is not shown in the
  inbox and appears in the terminal. *Cost if wrong:* such a question is answered in the
  terminal.
- **R2. No builder started a copy of the app** (a debug copy takes the keyboard from whoever
  sits at the Mac). On-screen behaviour was checked with app tests in off-screen windows; what
  only a person can see is the owner's hands-on list. *Cost if wrong:* a visual or focus problem
  is first seen by the owner.
- **R3. App tests live in several files** (InboxCenterTests, InboxPanelTests, HeldRequestTests,
  HookInstallerTests and others) instead of one. *No cost.*
- **R4. A held request talks to its connection through a small interface** so tests can fake
  it. *No visible effect.*
- **R5. The end-to-end check by hand was replaced by a test** that starts the real socket and
  runs the real built `singularity-hook` against it (held, answered, reply printed; no app →
  exits at once with no output). *Cost if wrong:* the real Claude Code → helper → app chain is
  first run on the owner's Mac.
- **R6. The live-test record (Task 0) had no separate review;** later tests use its shapes.
  *Cost if wrong:* a mis-recorded detail shows up in the owner's check.
- **R7. A held permission also goes back when the agent moves on:** the tab's status becomes
  working, done or idle, or Claude Code's end-of-turn hook arrives. That is the owner having
  answered in the terminal (Yes there does not end the hook). A held question is not released
  by "working", because Claude Code reports working while the question hook runs; it goes back
  on end of turn, done, idle or the program exiting. *Cost if wrong:* a stale permission card
  until the hold limit.
- **R8. Claude Code's second, permission-style request for a question** (it sends one whenever
  the question went back to the terminal) gets "no decision" at once and never makes a card.
  *Cost if wrong:* none seen.
- **R9. A done card shows Claude Code's last message** (from the end-of-turn hook), not the short
  summary in its status record, whichever arrives first. *Cost if wrong:* the card shows the
  summary.
- **R10. Small review findings were fixed at once** rather than parked. *Cost:* extra fix rounds.
- **R11. "Installed" means exactly what Install writes** (same matcher, same timeouts). A hook
  of ours with an old timeout, or only some of the three, reads as not installed, so the button
  says Install and repairs it. *Cost if wrong:* one extra Install press after a change.
- **R12. At most 5 browser approvals wait per Space;** one more is denied at once. *Why:* a page
  calling `prompt()` in a loop would otherwise flood cards, banners and Dock bounces (the sheet
  showed one at a time). *Cost if wrong:* an agent making more than 5 approval-needing calls at
  once in one Space gets some denied and has to retry.
- **R13. Allow, Allow on <site> and Deny ignore clicks for 0.5 s** after the inbox appears or a
  card is added, removed or moved. *Why:* the second click of a double-click on Deny must not land
  on the next card's Allow, and an inbox opening by itself must not catch a click meant for the
  page. *Cost if wrong:* a quick deliberate click is ignored once.
- **R14. An answer is checked against the Space's current policy:** an Allow given after the
  Space was switched to read-only (or deleted) becomes a deny. The approval rules themselves are
  unchanged. *Cost if wrong:* none seen.
- **R15. The helper does not half-close its connection** (the plan said it should). *Why:* on
  macOS the app cannot tell a half-closed connection from a closed one, and the close is how it
  learns that Claude Code ended the hook (Esc, Ctrl-C). *Cost if wrong:* none seen.
- **R16. A hook request counts only when it comes from a program running inside that tab**
  (checked through the process tree); otherwise "no decision". *Why:* the tab's id is inherited
  by tmux or screen started in a Singularity tab, and Claude Code in a terminal outside
  Singularity would then send its questions to the inbox. *Cost if wrong:* where the process tree
  can't show the link (a tool that re-parents Claude Code), questions stay in the terminal.
- **R17. The app answers each request with a "got it" byte within 5 s,** or the helper gives up
  and Claude Code shows its own prompt. *Why:* a hung app would otherwise leave Claude Code on a
  spinner for up to an hour. *Cost if wrong:* if Singularity is busy for more than 5 s, that one
  question falls back to the terminal.
- **R18. At most 5 held requests per tab;** a sixth gets "no decision" at once. *Cost if wrong:* a
  sixth simultaneous question or permission from one tab shows only in the terminal.

### Known rough edges (left for later)

- If the owner refuses banners when macOS asks and then allows them in System Settings, banners
  stay off until Singularity is restarted.
- Remove takes out a `"hooks": {}` or `"Stop": []` that was empty before Install, if the owner
  had such empty entries himself.
- An end-of-turn hook from one Claude Code session hands back held requests of every session in
  the same tab (one session per tab is the usual case).
- A program that flips its status between blocked and working faster than every 0.5 s keeps
  restarting the click lock of R13, so approvals can't be answered until it calms down (they
  are denied at the timeout, the safe side).
- An inbox panel moved to another window gets no click lock (R13).
- Whether Claude Code's status records and its probe reply survive herdr-core's `hc attach`
  was not tested.
