# Running agents: an overview in the inbox and a count on each Space

Owner decision, 2026-11-23. A small change; this is the short design.

## Why

The inbox shows only what needs the owner (questions, permissions, approvals, "done"). The owner
also wants to see **where anything is open at all**: which agents are running, in which Space,
working or idle, and get there with one click.

## What

- **What counts as a running agent (owner's choice "B").** A terminal tab whose foreground
  program is a known agent: `claude`, `codex`, or the first word of any launcher's command
  (`AppState.launchers`, e.g. `claude --resume` → `claude`). Dev servers, editors, `tail` etc. do
  not count. Only terminals with a live session (a herdr-core tab not opened since launch has
  none and is not listed). An agent inside tmux/screen is not seen (the foreground is the
  multiplexer).
- **State** comes from `TerminalBoard` (`InboxCenter.board`): working, waiting (needs the owner),
  idle/done/unknown. An agent that sends no status records (Codex) is "running", shown like idle.
- **Inbox panel: a "Running · N" section** under the cards, shown even with no cards (and the
  empty-state text adjusts). One row per running agent: a state dot, the terminal's sidebar name
  (`displayTitle`), the Space's emoji and name. Click = go to that terminal (same path as an
  entry's "Go to terminal": select Space and tab; that also clears its entries, as going there
  always does). No buttons that answer anything. Ordered by Space order, then sidebar order.
  Dot colours: working = accent, waiting = orange, otherwise grey.
- **Space rail:** each Space circle keeps its red "needs you" count top-right and gets a small
  count of running agents bottom-right: accent while at least one of them is working, grey when
  all are idle. No mark when none run.

## Non-goals

Nothing is saved; no history; no new signals or hooks; no actions on agents from the list (it is
an overview, not orchestration); no per-agent settings; no change to banners or the Dock badge.

## Approaches considered

- A: any non-shell foreground program counts. Rejected: dev servers would crowd the list.
- **B (chosen): known agent names (`claude`, `codex`, launcher commands).**
- C: only terminals that send status records. Rejected: Codex would be missing.

## Left to the builder

The pure rules (which program names count, the rows, the order, the per-Space counts and colour)
go in Core with tests; the app feeds them each terminal session's foreground program. Exact
sizes and fonts follow the existing badges and cards.
