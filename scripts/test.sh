#!/usr/bin/env bash
# Run the unit tests (Swift Testing) with the Xcode chosen in scripts/env.sh, the tests of the
# agents' launcher and of the release scripts (offline), then the bundled
# plugins' own TypeScript tests (Tests/plugins) with the vendored Bun, when it has been fetched
# (scripts/fetch-bun.sh).
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh
swift test "$@"
scripts/test-launcher.sh
scripts/test-release.sh
if [[ -x Vendor/bun/bun ]]; then
  Vendor/bun/bun test Tests/plugins
fi
