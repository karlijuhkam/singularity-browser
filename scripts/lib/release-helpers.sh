# Small pieces of scripts/release.sh that need no keychain, network or terminal of their own, so
# scripts/test-release.sh can test them. Sourced, not run:
#   source scripts/lib/release-helpers.sh

# first_identity <team> <name prefix>: reads "fingerprint<TAB>team<TAB>name" lines on stdin and prints
# "fingerprint<TAB>name" of the first one of <team> whose name starts with <prefix>; nothing if none.
# It reads all of its input on purpose: an awk that stops at the first match (`exit`) ends the pipe
# early, the program still writing into it dies of SIGPIPE, and under `set -o pipefail` that fails
# the whole release whenever the match is not the last line.
first_identity() {
  awk -F'\t' -v team="$1" -v prefix="$2" \
    '!found && $2 == team && index($3, prefix) == 1 { print $1 "\t" $3; found = 1 }'
}

# origin_is_repo <remote URL> <owner/name>: succeeds when the URL is GitHub's address of that
# repository, in any of the forms git accepts: https://github.com/owner/name, git@github.com:owner/name,
# ssh://git@github.com/owner/name, each with or without ".git" (GitHub ignores case in both parts).
origin_is_repo() {
  local url="$1" path
  case "$url" in
    https://github.com/*)   path="${url#https://github.com/}" ;;
    git@github.com:*)       path="${url#git@github.com:}" ;;
    ssh://git@github.com/*) path="${url#ssh://git@github.com/}" ;;
    *) return 1 ;;
  esac
  path="${path%/}"
  path="${path%.git}"
  [[ "$(tr '[:upper:]' '[:lower:]' <<<"$path")" == "$(tr '[:upper:]' '[:lower:]' <<<"$2")" ]]
}

# ask_to_publish <1 if --yes was given, else 0> [terminal]: the last question before the release
# commit. Succeeds with --yes, or when the answer typed in the terminal is y or Y. The answer is read
# from the terminal itself (/dev/tty; the second argument is for tests), never from stdin, which can
# be a pipe. Without a terminal it refuses, unless --yes was given.
ask_to_publish() {
  local answer=""
  if [[ "$1" == 1 ]]; then
    echo "Publishing without asking (--yes)."
    return 0
  fi
  local terminal="${2:-/dev/tty}"
  # Opening /dev/tty fails when the script has no terminal (started by another program).
  if ! { : <"$terminal"; } 2>/dev/null; then
    echo "error: there is no terminal to answer \"Publish?\"; run the release in a terminal, or add --yes." >&2
    return 1
  fi
  printf 'Publish? [y/N] '
  read -r answer <"$terminal" || true
  [[ "$answer" == y || "$answer" == Y ]]
}
