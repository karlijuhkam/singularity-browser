#!/bin/sh
# The program the fixture plugin of PluginDoorTests starts (through the real PluginProcess, outside
# the sandbox): it reaches the test app's agent socket through the built singularity-mcp, as the
# Assistant's `claude` does. Never the real `claude`: only the launcher and system tools.
#
# Arguments: mode, the launcher's path, the socket's path (orphan: also a folder for its files).
#   exec    the launcher replaces this script (same process: the program itself connects)
#   child   the launcher runs as a child of this script (the realistic shape: claude starts it)
#   orphan  the launcher runs in a process group of its own (job control), so it outlives this
#           script when the plugin's program is ended; its input is a `sleep` that never writes,
#           its output goes to <folder>/out, its pid to <folder>/pid. Then this script waits.
#
# With no socket listening there, singularity-mcp would start the app: so nothing runs without one.
mode="$1"
launcher="$2"
socket="$3"
if [ ! -S "$socket" ]; then
  echo "no socket at $socket" >&2
  exit 3
fi
SINGULARITY_MCP_SOCKET="$socket"
export SINGULARITY_MCP_SOCKET
case "$mode" in
  exec) exec "$launcher" ;;
  child) "$launcher"; exit $? ;;
  orphan)
    set -m
    /bin/sleep 300 </dev/null 2>/dev/null | "$launcher" >"$4/out" 2>&1 &
    echo "$!" >"$4/pid"
    wait
    ;;
  *) echo "unknown mode: $mode" >&2; exit 2 ;;
esac
