#!/usr/bin/env bash
# Build the app bundle and launch it. Any running instance is quit first.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$ROOT/scripts/build-app.sh"

if pgrep -x Singularity >/dev/null; then
  echo "→ quitting the running Singularity (answer its prompt if a terminal is busy)"
  osascript -e 'tell application id "dev.roosa.Singularity" to quit' >/dev/null 2>&1 &
  # Wait for the old process to exit before launching the new build; launching while it is
  # still shutting down fails with LaunchServices error -600.
  for _ in $(seq 1 120); do
    pgrep -x Singularity >/dev/null || break
    sleep 0.5
  done
  if pgrep -x Singularity >/dev/null; then
    echo "Singularity is still running (quit cancelled?). Not launching the new build." >&2
    exit 1
  fi
fi

open "$ROOT/build/Singularity.app"
