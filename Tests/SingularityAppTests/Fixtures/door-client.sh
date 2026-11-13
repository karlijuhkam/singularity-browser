#!/bin/sh
# The program the fixture plugin of PluginDoorTests starts (through the real PluginProcess, outside
# the sandbox): it reaches the test app's agent socket through the built singularity-mcp, as the
# Assistant's `claude` does. Never the real `claude`: only the launcher and system tools.
#
# Arguments: mode, the launcher's path, the socket's path.
#   exec   the launcher replaces this script (same process: the program itself connects)
#   child  the launcher runs as a child of this script (the realistic shape: claude starts it)
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
  *) echo "unknown mode: $mode" >&2; exit 2 ;;
esac
