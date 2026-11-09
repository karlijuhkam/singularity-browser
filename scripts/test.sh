#!/usr/bin/env bash
# Run unit tests. With only Command Line Tools installed (no Xcode), SwiftPM does not
# find the Swift Testing macro plugin on its own, so we point it there explicitly.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh
PLUGINS="$(xcode-select -p)/usr/lib/swift/host/plugins/testing"
if [[ -d "$PLUGINS" ]]; then
  exec swift test -Xswiftc -plugin-path -Xswiftc "$PLUGINS" "$@"
else
  exec swift test "$@"
fi
