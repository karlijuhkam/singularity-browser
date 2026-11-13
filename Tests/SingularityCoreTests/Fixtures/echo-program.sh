#!/bin/sh
# The program PluginProgramTests lets a test plugin start (through PluginProcess, outside the
# sandbox). Never the real `claude`: only system tools. The first argument picks what it does.
case "$1" in
  # Copies stdin to stdout, byte for byte, until stdin ends.
  echo) exec /bin/cat ;;
  # The numbers 1 to $2, one per line, as fast as it can.
  count) exec /usr/bin/seq 1 "$2" ;;
  # Some output, then exit status 7.
  exit) /usr/bin/seq 1 "$2"; exit 7 ;;
  # Its working directory, then its environment.
  env) /bin/pwd; exec /usr/bin/env ;;
  # A line on stderr, then ends.
  stderr) echo "a line on stderr" >&2; exit 0 ;;
  # Ignores SIGTERM, starts a child (which ignores it too), prints "<own pid> <child pid>" and
  # waits for ever.
  ignore-term)
    trap '' TERM
    /bin/sleep 300 &
    echo "$$ $!"
    while :; do /bin/sleep 1; done
    ;;
  # Starts a child (which keeps stdout open), prints its pid and exits at once, leaving it behind.
  leave-child)
    /bin/sleep 300 &
    echo "$!"
    exit 0
    ;;
  *) echo "unknown mode: $1" >&2; exit 2 ;;
esac
