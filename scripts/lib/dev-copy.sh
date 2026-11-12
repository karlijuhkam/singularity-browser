# Helpers for scripts/run.sh, kept apart so scripts/test-run.sh can test them without running it.
# Sourced, not run:
#   source scripts/lib/dev-copy.sh

# has_own_data_folder <ps text>: given `ps eww -o command= -p <pid>` of a running Singularity (its
# command line followed by its environment, which macOS shows for the user's own processes),
# succeeds when that copy runs with its own data folder: SINGULARITY_HOME set to an absolute path.
# The app ignores any other value (Paths.swift), so then it uses the real ~/Singularity. Text without
# an environment (ps could not read it) counts as the real data folder: never signal such a copy.
has_own_data_folder() {
  [[ "$1" == *" SINGULARITY_HOME=/"* ]]
}

# copy_decision <ps text> <still running: 1 or 0>: what run.sh may do with a running copy from
# build/, given its `ps eww` text (read first) and whether the pid still existed after that read.
# Prints one word:
#   signal  it has its own data folder: a development copy, may get SIGTERM
#   refuse  it runs on the real data, or its environment could not be read: never signal it
#   ignore  it has exited
copy_decision() {
  if [[ "$2" != 1 ]]; then
    echo ignore
  elif has_own_data_folder "$1"; then
    echo signal
  else
    echo refuse
  fi
}

# usable_data_folder <path>: succeeds when the app would use <path> as SINGULARITY_HOME, i.e. it is
# an absolute path. "dev" or a literal "~/dev" would be ignored, and the app would open the real data.
usable_data_folder() {
  [[ "$1" == /* ]]
}
