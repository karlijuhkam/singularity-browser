# The last check before release.sh makes the release commit. Sourced, not run:
#   source scripts/lib/release-guard.sh
#
# Steps 2 to 6 of a release take many minutes. Anything that changes the repository meanwhile (a
# file edited in another window, a commit made on main, a Package.resolved rewritten by the build)
# was never checked, tested or built, so it must not end up in or under the public release commit.

# release_commit_guard <head from step 1>: run from the repository's root. Succeeds when HEAD is still
# that commit and the only change is the version bump in Resources/Info.plist. Otherwise prints what
# changed and fails.
release_commit_guard() {
  local head changes
  head="$(git rev-parse HEAD)"
  if [[ "$head" != "$1" ]]; then
    echo "error: HEAD moved during the release: it was $1 in step 1 and is $head now." >&2
    return 1
  fi
  changes="$(git status --porcelain)"
  if [[ "$changes" != " M Resources/Info.plist" ]]; then
    echo "error: the only change before the release commit must be the version bump in" >&2
    echo "       Resources/Info.plist, but git status shows:" >&2
    printf '%s\n' "${changes:-(no changes)}" | sed 's/^/       /' >&2
    return 1
  fi
}
