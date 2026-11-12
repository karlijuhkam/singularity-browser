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

echo
if (( failures )); then echo "$failures run test(s) failed"; exit 1; fi
echo "run tests passed"
