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

# usable_data_folder <path>: succeeds when the app would use <path> as SINGULARITY_HOME, i.e. it is
# an absolute path. "dev" or a literal "~/dev" would be ignored, and the app would open the real data.
usable_data_folder() {
  [[ "$1" == /* ]]
}
