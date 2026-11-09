#!/usr/bin/env bash
# Manual check (not part of test.sh): does the plugin page-script prelude lock every frame a plugin
# can reach? Builds scripts/probe/main.swift with the real Sources/Singularity/Plugins/PluginPrelude.swift,
# serves scripts/probe/www on 127.0.0.1, and runs scripts/probe/frames.js as a plugin's page script.
# Prints "locked" or "UNLOCKED (...)" per route and a RESULT line. Known gaps (routes no script can
# hook, listed in frames.js and in the spec's Known limitations) are counted apart; anything under
# "new" is a regression or a route to hook. "network requests" counts fetches that got out (the
# unlocked routes' own probes). Run it after changing PluginPrelude.swift, and add a route to
# frames.js for every insertion API you hook.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh
work="$(mktemp -d)"
cleanup() {
  if [[ -n "${server_pid:-}" ]]; then kill "$server_pid" 2>/dev/null || true; wait "$server_pid" 2>/dev/null || true; fi
  rm -rf "$work"
}
trap cleanup EXIT

swiftc -O scripts/probe/main.swift Sources/Singularity/Plugins/PluginPrelude.swift -o "$work/probe"
python3 scripts/probe/server.py scripts/probe/www "$work/requests.log" > "$work/port" &
server_pid=$!
for _ in $(seq 50); do [[ -s "$work/port" ]] && break; sleep 0.1; done
port="$(cat "$work/port")"

"$work/probe" "http://127.0.0.1:$port/" scripts/probe/frames.js
leaks="$(grep -c '^/beacon' "$work/requests.log" || true)"
echo "network requests from the plugin world: $leaks"
