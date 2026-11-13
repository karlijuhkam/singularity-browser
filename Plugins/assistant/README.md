# Assistant

A chat in Singularity's side panel (or in a tab). You type, the Assistant answers, and the answer
streams in as it is written. You can type your next message while an answer is written; it is sent
once the answer is done (Return does nothing until then).

To add it: Settings → Plugins → Included with Singularity → Add (or View → Show Assistant, which
opens that page while it isn't added), then approve it.

## How it works

The Assistant has no AI of its own and no account of its own. It runs the `claude` program you
installed yourself, with the sign-in that program already has. So:

- **It counts against your Claude plan**, like using `claude` in a terminal. If your `claude` is
  signed in with an API account instead, the chat is billed to that account. The panel shows which
  ("Claude plan" or "API billing") next to the model, and says so once whenever that changes.
- Singularity never sees, stores or asks for a password, token or API key.
- If `claude` isn't signed in, the panel says so: open a terminal tab, run `claude`, sign in, then
  press Try Again.
- If your plan's limit is reached, the panel says so, unless the answer still comes (for example
  because extra usage is switched on).
- The model menu lists the models your `claude` offers. Bigger models use up a plan faster.
- If you keep several Claude accounts apart with `CLAUDE_CONFIG_DIR`, set the folder under the
  panel's settings (the gear). Empty means Claude's usual folder.

The conversation continues after a restart: Claude keeps its own copy of the session in its config
folder, and the plugin keeps the messages you see in its data folder. New Chat starts afresh and
deletes that copy. If Claude can no longer continue the old conversation, the old messages stay
greyed out and a new conversation starts (also when Claude only says so at your first message; then
type that message again).

Ways out when something hangs: Stop that brings no end of the answer within 5 seconds starts
`claude` again (the conversation is kept); "Connecting to Claude…" gets Try Again after 15 seconds;
and a page that couldn't reach the plugin at all has Try Again too.

## The tab in front and the browser's tools

The Assistant can look at your browser, only where you allow it.

- **What is sent, and when.** With every message you send, the Assistant asks Singularity which tab
  is in front and puts a short note before your text in what goes to `claude`: the Space (name and
  short name), the tab's id and kind, and its title and address. Title and address come from the
  page, so they are marked as untrusted, and `<` and `>` in them are replaced so a page can't close
  the mark. The note is never shown or saved (tool lines below may name the tab's title). When no tab is shared, no title or address is sent: the note only says nothing in front is visible. The line above the message box
  (the chip) shows what the next message will carry.
- **The switch.** The tab in front is shared only for a Space you switched the Assistant on for
  (the button under the chat). The Assistant's browser
  tools work the same way: the Spaces you opened to it, the Space's agent policy (read-only, ask,
  allow all) and the approvals you already know from outside agents. It uses Singularity's own
  agent door (`singularity-mcp`), so there is no second way into the browser, and every call is in
  the Space's agent log. It can't see or use terminals.
- **Switching off works forward only.** What was already sent stays in Claude's session for this
  conversation; New Chat ends that.
- **The per-site switch.** A site can be switched off for plugins in the site settings. A tab
  already on such a site is not shared. A click or a redirect can carry a tab onto such a site
  afterwards; the next call on it is then refused.
- **Tool lines.** Each call shows as a small line in the chat ("Read Invoice 42", "Opened ...",
  "Clicked on ..."), in order with the answer. A line for an acting call (open, go to, close,
  click, type) that runs longer than a moment adds "waiting for your OK"; a slow read does not.
  Lines are made from the call itself (its address, its search text, the title of the tab that
  was in front). What a tool answered, such as page text, is never shown in a line or saved.
- **If the browser's tools can't start**, the chat still works without them and a line above the
  message box says so, with Try Again.
- Without the app's browser door (a bare debug build) the Assistant is the plain chat it was in
  version 0.1: no browser tools, no note about the tab in front, and the chip shows nothing shared.

## What it can't do

- It can't see or use terminals.
- `claude` is started with none of its built-in tools, with no MCP servers but Singularity's own
  (not even the ones in your own Claude config), without your Claude settings files (so none of
  your hooks, plugins or CLAUDE.md) and without skills (see `provider-claude.ts`). Two things stay
  as they are: settings your organisation manages for Claude, and, only when the chat
  runs without the browser's tools (a build with no browser door, or when they couldn't start; no
  note is sent then), a message that starts with "/", which `claude` may read
  as one of its own commands (what it answers then is shown as the answer). With the browser's
  tools, every message starts with the note about the tab in front, so this does not apply.
- Answers are shown as text (with simple formatting). Links are shown as their address, never as
  something to click, and HTML in an answer is shown as it is, never run.

## Permissions, in plain words

- **Shows its own panel and tab**: the chat page (`panel.tsx`). It can't reach the internet or
  any website; it only talks to this plugin's background program.
- **Keeps `claude` running and talks to it**: the one program it may start, found on your PATH
  when you approve the plugin (also a PATH set in `.zshrc`). That program is not sandboxed: it uses the internet and acts as you.
  What keeps it to the browser's tools is how `provider-claude.ts` starts it (no tools of its own,
  one MCP server); review that file.
- **Knows the tab in front**: its Space, title and address, in Spaces where you switched it on.
- **Uses the browser's tools** (the ones outside agents have), in Spaces where you switched it on: read pages, and open,
  click and type under each Space's agent policy and approvals.
- **Passes these settings to it**: `CLAUDE_CONFIG_DIR` (only when you set a folder) and three
  names the Claude Agent SDK sets for its program (`CLAUDE_AGENT_SDK_VERSION`,
  `CLAUDE_CODE_ENTRYPOINT`, `CLAUDE_CODE_SDK_READS_SESSION_STATE`). Singularity builds the rest of
  the program's environment itself.
- **Installs 2 packages from the npm registry**: the Claude Agent SDK (`@anthropic-ai/claude-agent-sdk`,
  which talks to `claude`) and Preact (draws the page), at the exact versions in `package.json`
  and `bun.lock`, with the packages they use. Nobody reviews those; they are pinned.
- Its background program never uses the internet. `claude` does.

## Files

- `plugin.json` the manifest and permissions
- `background.ts` the state, and the messages between the page and the provider
- `front.ts` the note about the tab in front, the chip and the tool lines (pure, tested)
- `provider.ts` the small interface any provider implements; `provider-claude.ts` the Claude one
  (everything that knows about `claude` and the SDK is in that one file)
- `conversation.ts` the saved copy of the visible messages (`conversation.json` in the data folder)
- `panel.tsx`, `panel.css` the page; `view.ts` what it shows; `markdown.ts` draws answers
- Tests: `Vendor/bun/bun test Tests/plugins/assistant` from the repository root. They replay a
  recorded exchange with a fake `claude` and never run the real program.
