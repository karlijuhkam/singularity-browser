#!/usr/bin/env bash
# Run the unit tests (Swift Testing) with the Xcode chosen in scripts/env.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh
exec swift test "$@"
