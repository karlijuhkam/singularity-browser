# Notes: a Markdown editor as a tab

Date: 2026-11-16. Status: built. The owner asked for "a capable Notion-style notebook, not real
Notion, just a very good WYSIWYG editor, for lists and journals", said "start, and decide
yourself", and added while it was being built: "since these are .md files, I also want to open
.md files in Singularity". So every choice below is the builder's call unless marked **owner**.

## What it is

A fourth kind of tab: a **note**. A note is one Markdown file, edited as rich text (no Markdown
syntax on screen). The owner writes lists, to-do lists and journal entries next to the pages and
terminals of the same Space.

- **owner:** a very good WYSIWYG editor; lists and journals; not a Notion clone (no databases,
  no pages inside pages, no sharing).
- **owner:** any Markdown file on the disk can be opened the same way.

## Goals, non-goals

Goals: writing feels immediate (no save button, no syntax); the file stays plain Markdown that
any other program and any agent can read and write; a note never loses text and never
overwrites someone else's change silently; a note can't phone home or run what it contains.

Non-goals: databases, kanban, calendars, backlinks, a notes sidebar or folder tree, sync,
collaboration, export, templates, per-note history, find in note, printing, a Notion import.

Anti-goal: a format only Singularity can read.

## Approaches

1. **Markdown files, web editor in a locked web view, built on Tiptap/ProseMirror (chosen).**
   The editor's blocks are limited to what Markdown can say, so a file round-trips. The page is
   bundled with the app and shown like a plugin's page: own URL scheme, no network.
2. *A native editor (NSTextView / TextKit 2).* No new dependency, but block editing (to-do
   items, tables, a "/" menu, dragging blocks) on TextKit is months of work and still wouldn't
   feel like the editors the owner compared it to.
3. *A JSON document per note (the editor's own format).* Lossless for anything (colours,
   callouts, toggles), but only Singularity could read it, agents couldn't write it with their
   file tools, and "open any .md file" would be impossible.
4. *As a bundled plugin (like the Assistant).* Plugins can't write files outside their data
   folder and have one page each; a note per tab, files in the Space, and a Finder "Open With"
   don't fit that shape.

## Decisions

- **Scope.** "Notes integration" was on the out-of-scope list; a note is a tab type, which the
  scope rule allows, and the owner asked for it. Recorded as a scope change in `CLAUDE.md`.
- **Dependency.** Tiptap 3 (MIT, on ProseMirror), with `@tiptap/markdown` (uses `marked`) and
  `@floating-ui/dom`. Exact versions in `NoteEditor/package.json` + `bun.lock`, none newer than
  two weeks when added. It is a *build-time* dependency of one committed file
  (`Resources/note-editor/editor.js`, about 570 KB): building the app and running the tests need
  no npm and no network. `scripts/build-note-editor.sh` rebuilds it with the vendored Bun.
- **Where notes live.** `~/Singularity/spaces/<slug>/notes/`, any depth. Title = file name
  without `.md`. "Today's Note" is `notes/Journal/<yyyy-mm-dd>.md`. Pictures pasted or dropped
  into a note are saved in `assets/` next to it and referenced relatively.
- **Files from elsewhere.** A note tab's stored path is relative (in `notes/`) or absolute (a
  file the owner opened). For an absolute file the editor's folder is the file's own folder, so
  pictures and a rename stay beside it and nothing above it is reachable.
- **Saving.** 0.4 s after the last keystroke; also when the page loses focus, when the tab
  closes and when the app quits. Loading alone never writes (the editor would respell some
  Markdown). A save is refused when the file no longer says what the editor last read or wrote;
  the page then asks: Keep Mine / Load That Version.
- **The page is locked** like a plugin's page: non-persistent store, `connect-src 'none'`,
  pictures only from the note's folder, no WebRTC, navigation only on its own origin. HTML inside
  a note is shown as text, never parsed. Pictures on the web are not loaded.
- **Agents.** No agent tool lists, reads or acts on a note tab, `front` never names one, and
  `list_spaces` doesn't mention the notes folder. A note is the owner's diary; an agent the owner
  points at the folder can still read and write the files with its own file tools.
- **Finder.** Release bundles declare Markdown as a document type with rank Alternate (offered
  under "Open With", never made the default), for the same reason only release bundles claim
  web links.

## What the editor does

Headings 1-3, bulleted / numbered / to-do lists (nested, Tab and ⇧Tab), quote, code block,
divider, table, picture (paste or drop), link, bold / italic / strikethrough / inline code.
Markdown shortcuts while typing (`# `, `- `, `[ ] `, `1. `, `> `, three backticks, `---`).
"/" opens the block menu. Selecting text shows a small toolbar (with the link field). The grip
left of a block (or list item) drags it; a click on it selects the block. ⌘-click opens a link
in a new tab after the note. The title on top renames the file.

## As built

- Core: `Notes/NoteFiles.swift` (names, containment, list, save decision, files from elsewhere).
- App: `Notes/NotePageServer` (`singularity-note://editor/`), `NoteHost` (web view + file
  access), `NoteRegistry` (one host per tab, folder watching), `AppState+Notes`.
- Editor: `NoteEditor/src/` (TypeScript, no framework), built into `Resources/note-editor/`.
- Commands: New Note (⌘N), Today's Note (⌥⌘N), Open File… (⌘O; with a little window in front ⌘O
  keeps its old meaning), the palette (commands, and the Space's notes without a tab), a note
  row's "Show in Finder" and "Delete Note…" (to the Trash).
- Found while trying it in a trial copy: quitting with `.terminateLater` hangs when the quit
  comes from SIGTERM (the wait runs inside a main-queue block, where the main queue can't run).
  The quit is called off once, the editors write, and the app quits again by itself.

## Known limits

- A file another program wrote may be respelled on the first edit (`*` bullets become `-`,
  table columns are padded, HTML becomes escaped text). Nothing is respelled without an edit.
- Markdown the editor has no block for (footnotes, definition lists, front matter) is kept as
  the text it is, but may be escaped on save.
- No syntax colouring in code blocks, no picture resizing, no find in note, no print.
- A picture's file is not removed when the picture is deleted from the note.
- An older Singularity can't read a `space.json` that has a note tab (it reports the Space as
  unreadable and leaves the file alone).

## Not tried

By hand in the running app: typing itself, the "/" menu with the keyboard, dragging a block,
pasting a screenshot, the Open panel, Finder's "Open With" in a release bundle, a note in a
split, and ⌘Q with unsaved typing. Tests drive the real editor in an off-screen web view, and a
trial copy was started in the background (a note tab loads, a Markdown file handed to the app
opens as a note, SIGTERM quits within 2 s).
