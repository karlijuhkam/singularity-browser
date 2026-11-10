# Import from Arc: design

Status: **built on 2026-11-11.** The owner handed the design choices to the builder ("I'll allow
you to choose where design choices are needed and will review in the end"). Everything under
"Builder's calls" is open to that review.

## Intent: why

The owner's browser before Singularity is Arc, with years of Spaces, pinned tabs and folders.
Arc's sidebar maps closely onto Singularity's (Spaces, pinned tabs, folders, open tabs), and Arc
keeps it in one local JSON file. Moving in should be one menu item, not an afternoon of
copy-and-paste.

## Goals

1. File → Import from Arc… lists Arc's Spaces; the ticked ones become new Singularity Spaces.
2. Pinned tabs, folders and (optionally) the unpinned tabs come along, in Arc's order, with
   Arc's names and the Space's colour.
3. Arc is never changed. Importing twice just makes the Spaces twice.

## Non-goals

- **Logins and cookies.** Settled: not part of it. Arc is Chromium; its cookies are encrypted
  with a key in the Keychain and belong to another engine. The owner signs in again.
- History, passwords, extensions, Boosts, notes and easels.
- Merging into an existing Space, or keeping the two in step afterwards (that would be sync).
- Other browsers.

## How it maps

| Arc | Singularity |
|---|---|
| Space (title, theme colour) | a new Space (same name; colour from the theme's mid tone) |
| tab directly under "pinned" | pinned tab |
| folder | folder; its tabs inside it |
| folder inside a folder | a folder inside that folder (`Folder.parentID`); folders are listed before the tabs next to them |
| unpinned tab ("Today") | open tab (optional, on by default) |
| tab group, split view | their tabs, in place (the split itself is not rebuilt) |
| note, easel, `arc://…`, a tab without an address | left out, and counted in the sheet |

A tab's name is the name the owner gave it in Arc, else the page's saved title. Imported folders
start collapsed. New Spaces have agents off and get a free slug. Nothing is loaded at import:
tabs open their page when first shown, so hundreds of tabs cost nothing.

## The file

`~/Library/Application Support/Arc/StorableSidebar.json`, read once, never written. The format
is not documented; `ArcImport` in Core describes the parts it relies on. If the file is missing
the sheet offers a file picker; if it isn't shaped as expected the sheet says so and imports
nothing. Only `sidebar.containers` is used (the sync copies in the same file are ignored).

## Builder's calls (the owner can overrule any)

- Logins are out (see Non-goals).
- Always new Spaces, never a merge.
- Arc's favourites (the icon grid above the pinned tabs, kept per Arc profile) are **not**
  imported: they belong to a profile, not to a Space, and there is no obvious Space to put them in.
- Nested folders stay nested (changed 2026-11-11; they were first flattened to "Outer / Inner" names). Empty folders are kept.
- Arc profiles are only shown as a hint in the list; each Singularity Space has its own logins anyway.
- Spaces with nothing importable are not listed.

## Where things are

`Sources/SingularityCore/Import/ArcImport.swift` (reading and mapping, unit-tested in
`ArcImportTests.swift` with a small sidebar in Arc's shape), `Sources/Singularity/Import/ArcImportSheet.swift`,
`AppState.importArcSpaces`. The reader was run once against the owner's real Arc file (7 Spaces,
425 tabs, 46 folders); the sheet itself still needs the owner's click-through.
