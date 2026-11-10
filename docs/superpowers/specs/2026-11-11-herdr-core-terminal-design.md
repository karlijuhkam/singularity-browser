# herdr-core as an optional terminal engine: design

Status: **built on 2026-11-11.** The owner handed the design choices to the builder ("I'll allow
you to choose where design choices are needed and will review in the end"). Everything under
"Builder's calls" is open to that review.

## Intent: why

A terminal tab's shell is a child of Singularity. Quit the browser (or let it crash, or update
it) and every shell, and every agent running in one, dies with it. herdr-core (`hc`,
github.com/herdrdev/herdr-core, Apache-2.0) exists to solve exactly that: programs run under its
background "holder" and stay alive; viewers come and go. The owner already runs herdr-core. With
the option on, Singularity's terminal tabs become viewers of herdr terminals.

## Goals

1. A switch in Settings → Terminal, **off by default**: "Run terminals through herdr-core (hc)".
2. With it on, a terminal tab's shell survives Singularity quitting; the same tab shows the same
   shell, screen included, at the next launch.
3. Tab titles, the working directory, the "program still running" warnings and
   `SINGULARITY_SPACE` work as with the built-in terminal.
4. Nothing of herdr-core is bundled or re-implemented. Without `hc`, or when it misbehaves, a
   tab is the built-in terminal and says why.

## Non-goals

- Bundling `hc`, installing it, or updating it.
- Speaking herdr-core's socket protocol, or its holder's (which is internal to herdr-core).
- Showing herdr terminals that Singularity didn't start, agent orchestration, templates,
  remote machines (`--on`). CLAUDE.md: "we only host terminals".
- A plugin. Plugins are sandboxed and get no terminal; `hc` hands out a full shell.

## How it works

herdr-core's holder and "first paint" are used exactly as they are, through two commands:

1. **Start** (once per tab): `hc run --bg --json --no-parent --no-notify --name sg-<tab id>
   --cwd <dir> --label app=singularity --label space=<slug> -- /usr/bin/env
   SINGULARITY_SPACE=<slug> <login shell> -l`
2. **Show**: the tab's SwiftTerm view runs `hc attach sg-<tab id> --history 2000` where it would
   otherwise run the login shell. `hc attach` is an ordinary terminal program: raw bytes both
   ways, window size forwarded, and on attach the core repaints the current screen.

Details:

- **The name** is `sg-` plus the first 24 hex digits of the tab's id, which is stored in
  `space.json`. That is all the bookkeeping there is: after a restart the tab asks
  `hc get <name>` and attaches to what it finds. A finished terminal of that name is removed and
  a new one started.
- **`/usr/bin/env`**: herdr-core gives programs its own environment, not the caller's (`hc run`
  0.1.19 has no `--env`), so the Space's slug is passed this way.
- **`--no-parent`**: if Singularity was itself started from a herdr terminal, tabs must not
  become that terminal's children and end with it.
- **Title and directory**: `hc get` reports the shell's process id. The existing once-a-second
  check then works unchanged, except that the foreground process group is asked of the kernel by
  process id (`proc_pidinfo`), since the PTY belongs to herdr-core. `hc` is not polled.
- **When `hc attach` ends**, the tab asks `hc get`: finished means the shell ended (the usual
  rules: a clean exit closes the tab if that setting is on); still live means only the view let
  go (herdr's detach key, ctrl+\ by default, or the core restarting), and Return attaches again.
- **Closing a tab** ends its shell: `hc kill`, then `hc rm` once it has finished. A tab is the
  owner's handle on the shell; a shell without a tab would be invisible in Singularity.
- **Quitting the app** only ends the `hc attach` processes.
- **Fallback**: `hc` not found, not answering within 15 s, or answering something unexpected:
  the tab prints one dim line saying so and starts the built-in login shell.
- **Finding `hc`**: `~/.local/bin/hc`, `/opt/homebrew/bin/hc`, `/usr/local/bin/hc`, then `PATH`
  (an app started from the Dock has a short `PATH`).

## Things to know

- herdr-core calls its interface a preview (0.x, "the API only grows"). Built and checked
  against `hc` 0.1.19.
- Programs in a herdr terminal see `TERM_PROGRAM=ghostty` (herdr-core sets it), not `Singularity`.
- The switch applies to terminals opened after it is changed. Tabs already open keep their engine
  until they are closed or their shell ends.
- With the option on and then off again, shells started under herdr-core stay in herdr-core
  (`hc ls --label app=singularity`); their tabs open a built-in shell instead.
- `HC_SESSION` in Singularity's environment selects another herdr core, as for any `hc` call
  (used for testing next to the owner's own core).

## Builder's calls (the owner can overrule any)

- The CLI (`hc run`, `hc attach`, `hc get`, `hc kill`, `hc rm`), not the socket API.
- Closing a tab ends the shell; quitting does not.
- One name per tab, derived from the tab id; no list of herdr terminals in the app.
- Silent fallback to the built-in terminal, with one line of explanation in the tab.
- herdr's detach key is left alone; a detach is answered with "press Return to show it again".

## Where things are

`Sources/SingularityCore/Terminal/HerdrCore.swift` (finding `hc`, names, arguments, reading
`hc get`; unit-tested in `TerminalTests.swift`), `TerminalSession.swift` (the "herdr-core"
section), `TerminalRegistry.swift` (which engine a new session gets; what quitting does),
Settings → Terminal.

Checked by hand in a second copy of the app against an isolated herdr core (`HC_SESSION`):
start, title and directory tracking, a running program's name, quit and relaunch onto the same
shell (same process id, earlier output on screen), `exit` closing the tab and removing the herdr
terminal. Not exercised by hand: closing a tab from the sidebar, and the detach key.
