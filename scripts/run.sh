#!/usr/bin/env bash
# Build the app bundle and launch it. Any running instance is quit first.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$ROOT/scripts/build-app.sh"
osascript -e 'tell application id "dev.roosa.Singularity" to quit' >/dev/null 2>&1 || true
open "$ROOT/build/Singularity.app"
