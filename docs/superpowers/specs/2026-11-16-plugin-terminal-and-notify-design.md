# Two plugin permissions: open a terminal, show a notification

Status: decided by the owner 2026-11-16 ("both"), built the same day. This document is short
because the change is: two declared, approved abilities for plugins, in the mould of `commands`.

## Why

The owner's own plugin for `herdr-bot` (`~/Developer/singularity-herdr-bots`, not in this
repository) shows his Bots in a panel. Two things the Herdr app's panel did were out of a
plugin's reach: starting a Bot (it must run in a terminal tab) and a banner when a pilot run
needs him. Both were refused by design until now: "no agent tool, page or plugin can add or run
a launcher", and plugins had no notifications.

## What

- **`permissions.openTerminals: ["program", …]`** (at most 4). `singularity.terminal.open(program,
  args)` opens a new terminal tab in the Space in front, in the Space's own folder, and types
  `'<pinned path>' '<arg>' …` into its first shell, exactly as a launcher's command is typed
  (once, never saved, never after a restart). The tab is not selected.
- **`permissions.notifications: true`.** `singularity.notify(title, body)` shows a macOS
  notification titled `Plugin “<name>”`, with the plugin's text in the body.

Both answer `{ ok: true }` or `{ ok: false, error }`.

## Why this is not a wider door than plugins already had

A plugin with `commands` already runs a declared program **as the user, unsandboxed, with free
arguments after the checked words**, invisibly. A terminal tab running a declared program is the
same power made visible, and the owner can see and stop it. So the rules are `commands`' rules:

- The name is a bare program name, none of the refused ones (shells, interpreters, …).
- Its path is resolved on the login `PATH` at approval, shown on the approval sheet, pinned in
  the approval, and checked again at every use.
- Asking for a new name, or for notifications, is a widening: the plugin pauses until approved
  again, development mode or not.

What is new and needs its own rule is that the line is typed into a **shell**. So every argument
must be one plain word (letters, digits and `- . _ / : = @ + ,`, at most 200 bytes, at most 16
arguments); anything else refuses the whole request. A plugin picks arguments for its declared
program, never a second command. Every word, the path included, is then typed in single quotes
(see "From the review").

## Limits

- Terminals: 5 a minute, 2 s apart, per plugin. Notifications: 20 an hour, 5 s apart.
- At most 5 terminals a plugin opened may be open at once.
- A terminal opens only in the Space in front and not under the welcome flow, and not in a test
  copy (`ProgramPolicy`). It is **not selected**. No project picker (nobody is there to answer it).
- A notification is text: the plugin's title (cut to 80) and body (cut to 300), cleaned with
  `InboxText.clean`, shown as the body under the fixed title `Plugin “<name>”`. It belongs to no
  inbox entry, is not withdrawn with the inbox and adds nothing to the Dock badge. It is shown
  only when macOS already allows Singularity's notifications: a plugin never brings up the
  permission question.
- Only an approved plugin whose files are the approved ones gets either (`PluginManager`
  reads the permission from the approved manifest, whatever host.ts believed).

## From the review (before release)

An independent review found no way for an argument to become a second command in a stock shell,
and these, all fixed:

- **A banner could be forged.** The title used to be `<name>: <title>`, and the name is the
  author's: a plugin called "Claude Code · Work" with an empty title matched an inbox banner
  exactly. Now the title is always `Plugin “<name>”` and the plugin's words are the body.
- **zsh aliases made plain words into syntax.** A global alias (`G` for `| grep`, as oh-my-zsh's
  common-aliases defines) expands anywhere on a line, an alias or suffix alias can replace the
  command, and zsh reads `=name` as a path. So every word is single-quoted.
- **The new tab took the keyboard.** It was selected like a launcher's; a plugin picks the
  moment, so the owner's typing could land in it. Now it opens unselected, its shell is started
  at once, and it does not become the terminal an artifact's `prompt()` pastes into.
- No ceiling on open terminals (now 5 per plugin); a control character in the pinned path would
  act as a key (now refused); the pinned file was checked before the cheap limits (now after);
  a plugin could be the one to trigger macOS's notification question (now never).

Left as it is, knowingly: arguments are free (as the approval sheet says: "with arguments it
chooses"), so for some programs they amount to running anything (`make -f <file>`); the owner
decides that per program at approval. The line can be typed into something that isn't a prompt
when the owner's shell start-up asks a question (the same as for a launcher). A zsh function
named exactly like the path would still run instead of it (the owner's own configuration).

## Not done

- Opening a terminal in another Space, a folder or a project; a split; a title for the tab.
- Selecting, reading or typing into an existing terminal (the Assistant's `terminals` permission
  is the only way, with a card every time).
- A click on a plugin's banner going to the plugin's page: it opens the inbox, as every banner does.
- Sounds, buttons or images in a notification.

## Where

Core: `PluginManifest.Permissions` (`openTerminals`, `notifications`, `pinnedNames`),
`PluginActions.swift` (`PluginTerminalRules`, `PluginRateLimit`, `PluginNotice`), `PluginWire.appRequest`,
`PermissionDescriptions`, `PluginApproval`'s `widens`. App: `PluginManager.answerAppRequest`,
`AppState.openTerminal(typing:)`, `InboxNotifier.post(title:body:)`. Host: `singularity.terminal.open`,
`singularity.notify` in `Resources/plugin-host/host.ts`. Tests: `PluginActionsTests` (Core, with
the real host under Bun), `PluginActionsStateTests` (app; no shell, no real banner).

Not tried by hand: a real banner, and a real terminal opened by a plugin in the running app.
