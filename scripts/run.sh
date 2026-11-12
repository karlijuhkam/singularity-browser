#!/usr/bin/env bash
# Build the app bundle and launch it as a development copy with its own data folder, next to the
# installed (daily) copy. Only a previous development copy (this checkout's build) is quit first.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$ROOT/scripts/build-app.sh"

DEV_BINARY="$ROOT/build/Singularity.app/Contents/MacOS/Singularity"

# Pids of running copies whose executable is exactly DEV_BINARY. The path is compared as a plain
# string (not a regex, so special characters in $ROOT are harmless), and the installed copy in
# /Applications, which has the same name and bundle ID, never matches.
dev_pids() {
  local pid
  for pid in $(pgrep -x Singularity || true); do
    [ "$(ps -o comm= -p "$pid" 2>/dev/null | sed 's/^ *//')" = "$DEV_BINARY" ] && echo "$pid"
  done
  return 0
}

pids="$(dev_pids)"
if [ -n "$pids" ]; then
  echo "→ quitting the running development copy (answer its prompt if a terminal is busy)"
  # SIGTERM to those pids only: AppleScript's `tell application id` would reach the daily copy too.
  # The app turns SIGTERM into a normal quit (same as Cmd+Q), so its prompt and saves still run.
  kill -TERM $pids 2>/dev/null || true
  # Wait for the old process to exit before launching the new build; launching while it is
  # still shutting down fails with LaunchServices error -600.
  for _ in $(seq 1 120); do
    [ -z "$(dev_pids)" ] && break
    sleep 0.5
  done
  if [ -n "$(dev_pids)" ]; then
    echo "The development copy is still running. Not launching the new build." >&2
    exit 1
  fi
fi

HOME_DIR="${SINGULARITY_HOME:-$HOME/Singularity-dev}"
echo "→ data folder: $HOME_DIR"
echo "  It starts empty and is never a copy of ~/Singularity (the daily copy's data)."
# -n: a new instance, although the daily copy has the same bundle ID.
open -n --env SINGULARITY_HOME="$HOME_DIR" "$ROOT/build/Singularity.app"
