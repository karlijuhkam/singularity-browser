# Assistant

A chat in Singularity's side panel (or in a tab). You type, the Assistant answers, and the answer
streams in as it is written.

## How it works

The Assistant has no AI of its own and no account of its own. It runs the `claude` program you
installed yourself, with the sign-in that program already has. So:

- **It counts against your Claude plan**, like using `claude` in a terminal. If your `claude` is
  signed in with an API account instead, the chat is billed to that account. The panel shows which
  ("Claude plan" or "API billing") next to the model, and says so once whenever that changes.
- Singularity never sees, stores or asks for a password, token or API key.
- If `claude` isn't signed in, the panel says so: open a terminal tab, run `claude`, sign in, then
  press Try Again.
- The model menu lists the models your `claude` offers. Bigger models use up a plan faster.
- If you keep several Claude accounts apart with `CLAUDE_CONFIG_DIR`, set the folder under the
  panel's settings (the gear). Empty means Claude's usual folder.

The conversation continues after a restart: Claude keeps its own copy of the session in its config
folder, and the plugin keeps the messages you see in its data folder. New Chat starts afresh and
deletes that copy. If Claude can no longer continue the old conversation, the old messages stay
greyed out and a new conversation starts.

## What it can't do (yet)

- It can't see your pages, tabs or terminals, and it can't click, type, open or run anything.
  It can only chat.
- `claude` is started with none of its built-in tools, with no MCP servers at all (not even the
  ones in your own Claude config), without your Claude settings files (so none of your hooks,
  plugins or CLAUDE.md) and without skills (see `provider-claude.ts`). So all it can do is write
  text. Two things stay as they are: settings your organisation manages for Claude, and a message
  that starts with "/", which `claude` may read as one of its own commands.
- Answers are shown as text (with simple formatting). Links are shown as their address, never as
  something to click, and HTML in an answer is shown as it is, never run.

## Permissions, in plain words

- **Shows its own panel and tab**: the chat page (`panel.tsx`). It can't reach the internet or
  any website; it only talks to this plugin's background program.
- **Keeps `claude` running and talks to it**: the one program it may start, found on your PATH
  when you approve the plugin. That program is not sandboxed: it uses the internet and acts as you.
  What keeps it harmless is how `provider-claude.ts` starts it (no tools); review that file.
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
- `provider.ts` the small interface any provider implements; `provider-claude.ts` the Claude one
  (everything that knows about `claude` and the SDK is in that one file)
- `conversation.ts` the saved copy of the visible messages (`conversation.json` in the data folder)
- `panel.tsx`, `panel.css` the page; `view.ts` what it shows; `markdown.ts` draws answers
- Tests: `Vendor/bun/bun test Tests/plugins/assistant` from the repository root. They replay a
  recorded exchange with a fake `claude` and never run the real program.
