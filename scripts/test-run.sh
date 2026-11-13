#!/usr/bin/env bash
# Offline tests for scripts/run.sh's safety checks (scripts/lib/dev-copy.sh). run.sh itself is never
# run here: it builds, and it signals running copies of the app.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Checked first: bash 3.2 exits with status 0 when `source` finds no file and an EXIT trap is set.
for file in scripts/lib/dev-copy.sh scripts/run.sh; do
  [[ -f "$ROOT/$file" ]] || { echo "FAIL $file is missing"; exit 1; }
done
source "$ROOT/scripts/lib/dev-copy.sh"

failures=0
ok()   { echo "ok   $1"; }
bad()  { echo "FAIL $1"; failures=$((failures + 1)); }
expect()     { local name="$1"; shift; if "$@"; then ok "$name"; else bad "$name"; fi; }
expect_not() { local name="$1"; shift; if "$@"; then bad "$name"; else ok "$name"; fi; }

# What `ps eww -o command= -p <pid>` prints: the command line, then the environment.
APP_CMD="/Users/someone/src/Singularity-Browser/build/Singularity.app/Contents/MacOS/Singularity"
expect     "own data folder: SINGULARITY_HOME=/… in the environment" \
  has_own_data_folder "$APP_CMD HOME=/Users/someone SINGULARITY_HOME=/Users/someone/Singularity-dev TMPDIR=/var/folders/x"
expect     "own data folder: as the last variable" \
  has_own_data_folder "$APP_CMD HOME=/Users/someone SINGULARITY_HOME=/private/tmp/sg-x"
expect_not "real data: no SINGULARITY_HOME" \
  has_own_data_folder "$APP_CMD HOME=/Users/someone LOGNAME=someone TMPDIR=/var/folders/x"
expect_not "real data: no environment at all (ps could not read it)" \
  has_own_data_folder "$APP_CMD"
expect_not "real data: relative SINGULARITY_HOME (the app ignores it)" \
  has_own_data_folder "$APP_CMD HOME=/Users/someone SINGULARITY_HOME=dev"
expect_not "real data: empty SINGULARITY_HOME" \
  has_own_data_folder "$APP_CMD HOME=/Users/someone SINGULARITY_HOME= TMPDIR=/x"
expect_not "real data: only a variable whose name ends in SINGULARITY_HOME" \
  has_own_data_folder "$APP_CMD HOME=/Users/someone OLD_SINGULARITY_HOME=/private/tmp/x"
expect_not "real data: empty text (the process ended)" \
  has_own_data_folder ""

# copy_decision <ps text> <still running>: the only way run.sh decides to signal a pid.
OWN="$APP_CMD HOME=/Users/someone SINGULARITY_HOME=/Users/someone/Singularity-dev"
REAL="$APP_CMD HOME=/Users/someone LOGNAME=someone"
decision_is() { [ "$(copy_decision "$2" "$3")" = "$1" ]; }
expect "decision: own data folder, running → signal"            decision_is signal "$OWN" 1
expect "decision: real data, running → refuse"                  decision_is refuse "$REAL" 1
expect "decision: environment unreadable, running → refuse"     decision_is refuse "$APP_CMD" 1
expect "decision: empty text, still running → refuse"           decision_is refuse "" 1
expect "decision: relative SINGULARITY_HOME, running → refuse"  decision_is refuse "$APP_CMD SINGULARITY_HOME=dev" 1
expect "decision: exited (empty text) → ignore"                 decision_is ignore "" 0
expect "decision: exited after the read → ignore"               decision_is ignore "$OWN" 0

expect     "data folder: absolute path"        usable_data_folder /private/tmp/sg-dev
expect_not "data folder: relative path"        usable_data_folder dev
expect_not "data folder: unexpanded ~/"        usable_data_folder "~/dev"
expect_not "data folder: empty"                usable_data_folder ""

# Order in run.sh: both refusals come before the build (which replaces the bundle under a running
# copy). Read as text, never run.
line_of() { grep -n -m1 -F "$1" "$ROOT/scripts/run.sh" | cut -d: -f1; }
BUILD_LINE="$(line_of '"$ROOT/scripts/build-app.sh"')"
expect "run.sh: the SINGULARITY_HOME check comes before the build" \
  [ "$(line_of 'if ! usable_data_folder')" -lt "$BUILD_LINE" ]
expect "run.sh: the real-data check comes before the build" \
  [ "$(line_of 'refuse_copy_on_real_data   #')" -lt "$BUILD_LINE" ]
expect "run.sh: kill only after the checks" \
  [ "$(line_of 'kill -TERM')" -gt "$BUILD_LINE" ]
# Exactly one kill, of one pid, in the "signal" branch of a fresh pid_decision.
expect "run.sh: one kill, for a single pid" \
  [ "$(grep -c 'kill ' "$ROOT/scripts/run.sh")" = 1 -a -n "$(grep -F 'kill -TERM "$pid"' "$ROOT/scripts/run.sh")" ]
expect "run.sh: the kill is in the signal branch of pid_decision" \
  [ "$(line_of 'case "$(pid_decision "$pid")" in')" -lt "$(line_of '    signal)')" \
    -a "$(line_of '    signal)')" -lt "$(line_of 'kill -TERM')" \
    -a "$(( $(line_of 'kill -TERM') - $(line_of '    signal)') ))" -le 2 ]
expect "run.sh: the wait is only for the signalled pids" \
  grep -q 'for pid in \$signalled' "$ROOT/scripts/run.sh"

echo
if (( failures )); then echo "$failures run test(s) failed"; exit 1; fi
echo "run tests passed"
