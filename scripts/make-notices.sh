#!/usr/bin/env bash
# Regenerates Resources/THIRD-PARTY-NOTICES.txt: the licences of everything shipped inside
# Singularity.app. Run it after changing dependencies (it reads SwiftPM's checkouts, so build
# once first). The file is committed, and build-app.sh / release.sh copy it into the app.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="Resources/THIRD-PARTY-NOTICES.txt"
BUN_VERSION="$(sed -n 's/^BUN_VERSION="\{0,1\}\([0-9.]*\)"\{0,1\}.*/\1/p' scripts/fetch-bun.sh | head -1)"
[[ -d .build/checkouts ]] || { echo "error: no .build/checkouts; run scripts/test.sh once first" >&2; exit 1; }

{
  echo "Singularity includes the following third-party software."
  echo
  echo "================================================================================"
  echo "Bun ${BUN_VERSION} (Contents/Helpers/bun), unmodified binary from https://bun.sh"
  echo "================================================================================"
  echo "Bun is MIT-licensed and statically links other projects, among them JavaScriptCore"
  echo "(LGPL-2.1). Its full licence text and the list of its bundled dependencies:"
  echo "https://github.com/oven-sh/bun/blob/bun-v${BUN_VERSION}/LICENSE.md"
  echo "The binary is a separate file in the app, so it can be replaced with another build of Bun."
  echo
  for dir in .build/checkouts/*/; do
    name="$(basename "$dir")"
    version="$(python3 - "$name" <<'PY'
import json, sys
pins = json.load(open("Package.resolved"))["pins"]
print(next((p["state"].get("version") or p["state"].get("revision", "") for p in pins if p["identity"] == sys.argv[1].lower()), ""))
PY
)"
    echo "================================================================================"
    echo "$name $version"
    echo "================================================================================"
    for file in "$dir"LICENSE* "$dir"NOTICE*; do
      [[ -f "$file" ]] || continue
      cat "$file"
      echo
    done
  done
} > "$OUT"
echo "✓ $OUT ($(wc -l < "$OUT" | tr -d ' ') lines)"
