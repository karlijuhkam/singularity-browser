#!/usr/bin/env bash
# Tests which app the singularity-mcp launcher starts. It only ever runs the launcher in dry-run
# mode (SINGULARITY_MCP_DRY_RUN=1: print the `open` command, connect to nothing, start nothing),
# so it can never start or reach a real copy of the app.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh

swift build --product singularity-mcp >/dev/null
BIN="$(swift build --product singularity-mcp --show-bin-path)/singularity-mcp"

TMP="$(mktemp -d /private/tmp/sg-launcher-XXXX)"
trap 'rm -rf "$TMP"' EXIT

# A bundle path with a space in it.
BUNDLE="$TMP/a b/Singularity.app"
mkdir -p "$BUNDLE/Contents/MacOS"
cp "$BIN" "$BUNDLE/Contents/MacOS/singularity-mcp"
ln -s "$BUNDLE/Contents/MacOS/singularity-mcp" "$TMP/link-to-launcher"

failures=0
check() { # name, expected, actual
  if [[ "$2" == "$3" ]]; then
    echo "ok   $1"
  else
    echo "FAIL $1"; echo "  expected: $2"; echo "  actual:   $3"
    failures=$((failures + 1))
  fi
}
dry() { SINGULARITY_MCP_DRY_RUN=1 "$1" </dev/null; }

check "inside a bundle" "open -g $BUNDLE" "$(dry "$BUNDLE/Contents/MacOS/singularity-mcp")"
check "through a symlink" "open -g $BUNDLE" "$(dry "$TMP/link-to-launcher")"
check "bare binary" "open -g -b dev.roosa.Singularity" "$(dry "$BIN")"

exit $((failures > 0 ? 1 : 0))
