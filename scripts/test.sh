#!/usr/bin/env bash
# Run the unit tests (Swift Testing) with the Xcode chosen in scripts/env.sh, the tests of the
# agents' launcher, of the release scripts and of run.sh's checks (offline), then the bundled
# plugins' own TypeScript tests (Tests/plugins) and the tests of the apps' host script
# (Tests/apps: wrangler.jsonc, the D1 wrapper, the Worker host) with the vendored Bun, when it has
# been fetched (scripts/fetch-bun.sh).
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh
swift test "$@"
scripts/test-launcher.sh
scripts/test-release.sh
scripts/test-run.sh
if [[ -x Vendor/bun/bun ]]; then
  Vendor/bun/bun test Tests/plugins
  Vendor/bun/bun test Tests/apps
fi
