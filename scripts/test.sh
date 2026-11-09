#!/usr/bin/env bash
# Run the unit tests (Swift Testing) with the Xcode chosen in scripts/env.sh, then the bundled
# plugins' own TypeScript tests (Tests/plugins) with the vendored Bun, when it has been fetched
# (scripts/fetch-bun.sh).
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh
swift test "$@"
if [[ -x Vendor/bun/bun ]]; then
  Vendor/bun/bun test Tests/plugins
fi
