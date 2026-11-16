#!/usr/bin/env bash
#
# Builds the note editor (NoteEditor/src) into Resources/note-editor/: editor.js (one file, with
# Tiptap and ProseMirror inside), editor.css and index.html. The built files are committed, so
# building the app and running the tests need no npm and no network; run this script only after
# changing NoteEditor/ and commit what it writes.
#
# Packages are the exact versions in NoteEditor/package.json and bun.lock, installed with the
# vendored Bun, without running any package's install scripts.
#
# To change a package: edit package.json, run `Vendor/bun/bun install --cwd NoteEditor
# --ignore-scripts --minimum-release-age 1209600` (nothing newer than two weeks), then this
# script, then scripts/make-notices.sh.

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUN="$ROOT/Vendor/bun/bun"
OUT="$ROOT/Resources/note-editor"

[[ -x "$BUN" ]] || "$ROOT/scripts/fetch-bun.sh"

echo "→ installing the editor's packages (as pinned in bun.lock)"
"$BUN" install --cwd "$ROOT/NoteEditor" --frozen-lockfile --ignore-scripts

mkdir -p "$OUT"
echo "→ building editor.js"
"$BUN" build "$ROOT/NoteEditor/src/editor.ts" --outfile "$OUT/editor.js" --target browser --format esm --minify
cp "$ROOT/NoteEditor/src/index.html" "$ROOT/NoteEditor/src/editor.css" "$OUT/"
echo "✓ $OUT ($(wc -c < "$OUT/editor.js" | tr -d ' ') bytes of script)"
