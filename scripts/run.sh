#!/usr/bin/env bash
# Build the app bundle and launch it as a development copy with its own data folder, next to the
# installed (daily) copy. Only a previous development copy (this checkout's build) is quit first.
#
# Refused, before anything is built:
# - SINGULARITY_HOME that is not an absolute path: the app ignores it and would open the real data.
# - A copy running from this checkout's build/ WITHOUT its own data folder (or whose environment
#   cannot be read): that is a daily copy on the real ~/Singularity (as before the first release is
#   installed in /Applications). It is never signalled, and its bundle is not replaced under it:
#   quit it yourself (Cmd+Q) and run this again.
# A copy with its own data folder gets SIGTERM, decided again for each pid right before signalling.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/scripts/lib/dev-copy.sh"

HOME_DIR="${SINGULARITY_HOME:-$HOME/Singularity-dev}"
if ! usable_data_folder "$HOME_DIR"; then
  echo "error: SINGULARITY_HOME must be an absolute path (it is \"$HOME_DIR\"); the app ignores any" >&2
  echo "       other value and would open your real data in ~/Singularity." >&2
  exit 1
fi

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

# pid_decision <pid>: "signal", "refuse" or "ignore" (copy_decision in scripts/lib/dev-copy.sh) for
# that pid right now. `ps eww` adds the process's environment to its command line. It is read first;
# then `ps -p` tells whether the pid still exists, so empty text from a live copy means "refuse".
pid_decision() {
  local text alive=0
  text="$(ps eww -o command= -p "$1" 2>/dev/null || true)"
  if ps -p "$1" >/dev/null 2>&1; then alive=1; fi
  copy_decision "$text" "$alive"
}

refuse_message() {
  echo "error: a copy of Singularity running from build/ uses your real data, or its data folder" >&2
  echo "       could not be read (pid $1). Quit it yourself (Cmd+Q) and run scripts/run.sh again." >&2
  exit 1
}

# Stops the script if any copy from build/ may not be signalled.
refuse_copy_on_real_data() {
  local pid
  for pid in $(dev_pids); do
    if [[ "$(pid_decision "$pid")" == refuse ]]; then refuse_message "$pid"; fi
  done
}

refuse_copy_on_real_data   # before building: build-app.sh replaces the bundle under a running copy
"$ROOT/scripts/build-app.sh"
refuse_copy_on_real_data   # again: one may have started during the build

# The copies to quit. SIGTERM goes to those pids only: AppleScript's `tell application id` would
# reach the daily copy too. The app turns SIGTERM into a normal quit (same as Cmd+Q), so its prompt
# and saves still run. Each pid's environment is read again right before it is signalled.
signalled=""
for pid in $(dev_pids); do
  case "$(pid_decision "$pid")" in
    signal)
      [ -n "$signalled" ] || echo "→ quitting the running development copy (answer its prompt if a terminal is busy)"
      kill -TERM "$pid" 2>/dev/null || true
      signalled="$signalled $pid" ;;
    refuse) refuse_message "$pid" ;;
    *) ;;   # exited meanwhile
  esac
done

# Wait for the signalled copies (only those) to exit before launching the new build; launching
# while one is still shutting down fails with LaunchServices error -600.
any_signalled_running() {
  local pid
  for pid in $signalled; do
    if ps -p "$pid" >/dev/null 2>&1; then return 0; fi
  done
  return 1
}
if [ -n "$signalled" ]; then
  for _ in $(seq 1 120); do
    any_signalled_running || break
    sleep 0.5
  done
  if any_signalled_running; then
    echo "The development copy is still running. Not launching the new build." >&2
    exit 1
  fi
fi

echo "→ data folder: $HOME_DIR"
echo "  It starts empty and is never a copy of ~/Singularity (the daily copy's data)."
# -n: a new instance, although the daily copy has the same bundle ID.
open -n --env SINGULARITY_HOME="$HOME_DIR" "$ROOT/build/Singularity.app"
