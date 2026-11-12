#!/usr/bin/env bash
# Offline tests for the release scripts: scripts/lib/*.sh, scripts/appcast.sh and the checks at the
# start of scripts/release.sh. No build, no network, no keychain.
#
# release.sh only ever runs here in a throwaway git repository under /private/tmp (a copy of the
# scripts and Resources/Info.plist, on a branch named main), and always with RELEASE_CHECKS_ONLY=1,
# which stops it right after its local checks. So even a broken check can never reach a build,
# the network, GitHub or the keychain.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Checked first: bash 3.2 exits with status 0 when `source` finds no file and an EXIT trap is set.
for file in scripts/lib/version.sh scripts/lib/release-guard.sh scripts/lib/release-helpers.sh \
            scripts/appcast.sh scripts/release.sh; do
  [[ -f "$ROOT/$file" ]] || { echo "FAIL $file is missing"; exit 1; }
done

TMP="$(mktemp -d /private/tmp/sg-rel-XXXX)"
trap 'rm -rf "$TMP"' EXIT

failures=0
ok()   { echo "ok   $1"; }
bad()  { echo "FAIL $1"; [[ -n "${2:-}" ]] && printf '  %s\n' "$2"; failures=$((failures + 1)); }
# expect <name> <command…>: passes when the command succeeds.
expect()     { local name="$1"; shift; if "$@"; then ok "$name"; else bad "$name"; fi; }
# expect_not <name> <command…>: passes when the command fails.
expect_not() { local name="$1"; shift; if "$@"; then bad "$name"; else ok "$name"; fi; }
contains()   { [[ "$1" == *"$2"* ]]; }

# ---- version.sh ---------------------------------------------------------------------------------
source "$ROOT/scripts/lib/version.sh"

expect     "0.10.0 > 0.9.9"           version_gt 0.10.0 0.9.9
expect     "0.2.0 > 0.1.0"            version_gt 0.2.0 0.1.0
expect     "1.0.0 > 0.99.99"          version_gt 1.0.0 0.99.99
expect_not "0.1.0 is not > 0.1.0"     version_gt 0.1.0 0.1.0
expect_not "0.1.9 is not > 0.2.0"     version_gt 0.1.9 0.2.0
expect     "valid: 0.2.0"             valid_version 0.2.0
expect     "valid: 10.20.30"          valid_version 10.20.30
expect_not "invalid: 0.2"             valid_version 0.2
expect_not "invalid: v0.2.0"          valid_version v0.2.0
expect_not "invalid: 0.2.0-beta"      valid_version 0.2.0-beta
expect_not "invalid: 1.2.3.4"         valid_version 1.2.3.4
expect_not "invalid: empty"           valid_version ""
expect_not "invalid: 0.2.0 + newline" valid_version $'0.2.0\n'

# set_plist_version changes the two values and nothing else in the file (comments stay).
cp "$ROOT/Resources/Info.plist" "$TMP/Info.plist"
set_plist_version "$TMP/Info.plist" 7.8.9 42
PB=/usr/libexec/PlistBuddy
expect "plist: short version set" [ "$($PB -c 'Print CFBundleShortVersionString' "$TMP/Info.plist")" = 7.8.9 ]
expect "plist: build set"         [ "$($PB -c 'Print CFBundleVersion' "$TMP/Info.plist")" = 42 ]
changed="$(diff "$ROOT/Resources/Info.plist" "$TMP/Info.plist" | grep -c '^[<>]' || true)"
expect "plist: only two lines changed" [ "$changed" = 4 ]

# ---- release-helpers.sh -------------------------------------------------------------------------
source "$ROOT/scripts/lib/release-helpers.sh"

# first_identity, as release.sh uses it: at the end of a pipe, under `set -euo pipefail`. The
# producer writes far more than a pipe holds after the match, so a filter that stopped reading at
# the first match would kill it with SIGPIPE (status 141) and fail the pipeline.
TAB=$'\t'
identity_lines() {   # identity_lines <line>…: those lines, then 20000 lines of another team
  printf '%s\n' "$@"
  local i
  for ((i = 0; i < 20000; i++)); do printf 'FFFF%05d\tOTHERTEAM1\tApple Development: Someone Else\n' "$i"; done
}
pick() {   # pick <team> <prefix> <line>…: runs first_identity in a subshell with pipefail; output in $OUT
  local team="$1" prefix="$2" status=0; shift 2
  OUT="$( set -euo pipefail; identity_lines "$@" | first_identity "$team" "$prefix" )" || status=$?
  return "$status"
}
expect "identity: match on the first line, pipefail holds" \
  pick T748B76PPL "Apple Development" "AAAA${TAB}T748B76PPL${TAB}Apple Development: Owner (X1)"
expect "identity: … prints fingerprint and name"  [ "$OUT" = "AAAA${TAB}Apple Development: Owner (X1)" ]
expect "identity: two matches, the first wins" \
  pick T748B76PPL "Apple Development" \
  "BBBB${TAB}T748B76PPL${TAB}Apple Development: Owner (X1)" "CCCC${TAB}T748B76PPL${TAB}Apple Development: Owner (X2)"
expect "identity: … it is the first"               [ "$OUT" = "BBBB${TAB}Apple Development: Owner (X1)" ]
expect "identity: other teams and other names are skipped" \
  pick T748B76PPL "Developer ID Application" \
  "DDDD${TAB}OTHERTEAM1${TAB}Developer ID Application: Other" "EEEE${TAB}T748B76PPL${TAB}Apple Development: Owner" \
  "FFFF${TAB}T748B76PPL${TAB}Developer ID Application: Owner"
expect "identity: … the team's Developer ID"       [ "$OUT" = "FFFF${TAB}Developer ID Application: Owner" ]
expect "identity: no match, no output, no failure" pick T748B76PPL "Developer ID Application"
expect "identity: … empty"                         [ -z "$OUT" ]

expect     "origin: https"                   origin_is_repo https://github.com/owner/repo owner/repo
expect     "origin: https .git"              origin_is_repo https://github.com/owner/repo.git owner/repo
expect     "origin: ssh scp form"            origin_is_repo git@github.com:owner/repo.git owner/repo
expect     "origin: ssh scp form, no .git"   origin_is_repo git@github.com:owner/repo owner/repo
expect     "origin: ssh:// form"             origin_is_repo ssh://git@github.com/owner/repo.git owner/repo
expect     "origin: trailing slash"          origin_is_repo https://github.com/owner/repo/ owner/repo
expect     "origin: case is ignored"         origin_is_repo https://github.com/Owner/Repo.git owner/repo
expect_not "origin: another repository"      origin_is_repo https://github.com/owner/other.git owner/repo
expect_not "origin: a longer name"           origin_is_repo https://github.com/owner/repo-fork owner/repo
expect_not "origin: another owner"           origin_is_repo git@github.com:someone/repo.git owner/repo
expect_not "origin: another host"            origin_is_repo https://gitlab.com/owner/repo.git owner/repo
expect_not "origin: a path below it"         origin_is_repo https://github.com/owner/repo/extra owner/repo
expect_not "origin: a local path"            origin_is_repo /private/tmp/owner/repo owner/repo

# ask_to_publish reads the answer from a terminal (a file here); only y or Y publishes.
ask() {   # ask <--yes: 0|1> <answer, or "none" for no terminal>; output in $OUT
  local status=0 terminal="$TMP/terminal"
  if [[ "$2" == none ]]; then terminal="$TMP/no-such-terminal"; else printf '%s\n' "$2" >"$terminal"; fi
  OUT="$(ask_to_publish "$1" "$terminal" 2>&1 </dev/null)" || status=$?
  return "$status"
}
expect     "publish? y publishes"                ask 0 y
expect     "publish? … the question was asked"   contains "$OUT" "Publish? [y/N]"
expect     "publish? Y publishes"                ask 0 Y
expect_not "publish? n stops"                    ask 0 n
expect_not "publish? yes stops (only y or Y)"    ask 0 yes
expect_not "publish? an empty answer stops"      ask 0 ""
expect_not "publish? no terminal stops"          ask 0 none
expect     "publish? … and says to add --yes"    contains "$OUT" "--yes"
expect     "publish? --yes without a terminal"   ask 1 none
expect     "publish? --yes does not ask"         ask 1 n

# ---- appcast.sh ---------------------------------------------------------------------------------
NOTES="$TMP/notes.txt"
printf '%s\n' 'Fix <b>bold</b> & more' '' 'ends ]]> here' > "$NOTES"
URL="https://github.com/karlijuhkam/singularity-browser/releases/download/v0.2.0/Singularity-0.2.0.zip"
XML="$TMP/appcast.xml"
if "$ROOT/scripts/appcast.sh" --version 0.2.0 --build 2 --url "$URL" --length 123 \
     --signature 'c2lnbmF0dXJl+/=' --min-system 14.0 --notes-file "$NOTES" --out "$XML"; then
  ok "appcast: written"
  CAST="$(cat "$XML")"
  expect     "appcast: well-formed XML"        xmllint --noout "$XML"
  expect     "appcast: build"                  contains "$CAST" 'sparkle:version>2<'
  expect     "appcast: short version"          contains "$CAST" 'shortVersionString>0.2.0<'
  expect     "appcast: minimum macOS"          contains "$CAST" 'minimumSystemVersion>14.0<'
  expect     "appcast: title"                  contains "$CAST" '<title>Singularity 0.2.0</title>'
  expect     "appcast: enclosure URL"          contains "$CAST" "url=\"$URL\""
  expect     "appcast: length"                 contains "$CAST" 'length="123"'
  expect     "appcast: signature"              contains "$CAST" 'sparkle:edSignature="c2lnbmF0dXJl+/="'
  expect     "appcast: notes are escaped"      contains "$CAST" '&lt;b&gt;'
  expect     "appcast: ]]> cannot end CDATA"   contains "$CAST" 'ends ]]&gt; here'
  expect     "appcast: two <li>"               [ "$(grep -o '<li>' "$XML" | wc -l | tr -d ' ')" = 2 ]
  expect_not "appcast: no channel element"     contains "$CAST" 'sparkle:channel'
  # The description, read back through an XML parser, is the escaped HTML list.
  DESC="$(xmllint --xpath 'string(//item/description)' "$XML")"
  expect     "appcast: description round-trips" [ "$DESC" = '<ul><li>Fix &lt;b&gt;bold&lt;/b&gt; &amp; more</li><li>ends ]]&gt; here</li></ul>' ]
else
  bad "appcast: written"
fi
# appcast_refuses <expected message part> <arguments…>: appcast.sh fails, says why, writes nothing.
appcast_refuses() {
  local expected="$1" out status=0; shift
  out="$("$ROOT/scripts/appcast.sh" "$@" --out "$TMP/x.xml" 2>&1)" || status=$?
  (( status != 0 )) && [[ "$out" == *"$expected"* ]] && [[ ! -e "$TMP/x.xml" ]]
}
expect "appcast: refuses a missing argument" appcast_refuses "usage" \
  --version 0.2.0 --build 2 --url "$URL" --length 123
expect "appcast: refuses a bad length" appcast_refuses "length" \
  --version 0.2.0 --build 2 --url "$URL" --length 12a --signature s --min-system 14.0 --notes-file "$NOTES"
expect "appcast: refuses empty notes" appcast_refuses "no text" \
  --version 0.2.0 --build 2 --url "$URL" --length 123 --signature s --min-system 14.0 --notes-file /dev/null

# ---- release.sh checks, in a throwaway repository -----------------------------------------------
REPO="$TMP/repo"
mkdir -p "$REPO/scripts/lib" "$REPO/Resources"
cp "$ROOT/scripts/release.sh" "$ROOT/scripts/appcast.sh" "$ROOT/scripts/env.sh" "$REPO/scripts/"
cp "$ROOT"/scripts/lib/*.sh "$REPO/scripts/lib/"
cp "$ROOT/Resources/Info.plist" "$REPO/Resources/"
printf 'dist/\n' > "$REPO/.gitignore"
CURRENT="$($PB -c 'Print CFBundleShortVersionString' "$REPO/Resources/Info.plist")"
git -C "$REPO" init -q -b main
git -C "$REPO" add -A
git -C "$REPO" -c user.name=test -c user.email=test@invalid commit -q -m "test setup"
cp "$REPO/Resources/Info.plist" "$TMP/Info.plist.before"

# release <args…>: runs the copy's release.sh, stopping after the local checks; output in $OUT.
release() {
  local status=0
  OUT="$(cd "$REPO" && RELEASE_CHECKS_ONLY=1 scripts/release.sh "$@" 2>&1)" || status=$?
  return "$status"
}
clean_tree() { [[ -z "$(git -C "$REPO" status --porcelain)" ]]; }
plist_unchanged() { cmp -s "$TMP/Info.plist.before" "$REPO/Resources/Info.plist"; }

expect_not "release: no argument refused"            release
expect     "release: … and the tree stays clean"     clean_tree
expect_not "release: 0.2 refused"                    release 0.2
expect     "release: … message names the version"    contains "$OUT" "0.2"
expect     "release: … and the tree stays clean"     clean_tree
expect_not "release: $CURRENT (not higher) refused"  release "$CURRENT"
expect     "release: … message says not higher"      contains "$OUT" "not higher"
expect     "release: … and the tree stays clean"     clean_tree
expect_not "release: 0.0.1 (lower) refused"          release 0.0.1
expect_not "release: --skip-notarize with a version refused" release 9.9.9 --skip-notarize
expect_not "release: --yes with --skip-notarize refused" release --skip-notarize --yes
expect     "release: 9.9.9 --yes passes the local checks" release 9.9.9 --yes

# The control: with nothing wrong, the local checks pass (so the refusals above are real).
expect     "release: 9.9.9 passes the local checks"  release 9.9.9
expect     "release: … and stops there"              contains "$OUT" "RELEASE_CHECKS_ONLY"

git -C "$REPO" tag v9.9.9
expect_not "release: existing tag v9.9.9 refused"    release 9.9.9
expect     "release: … message names the tag"        contains "$OUT" "v9.9.9"
git -C "$REPO" tag -d v9.9.9 >/dev/null

git -C "$REPO" checkout -q -b feature
expect_not "release: not on main refused"            release 9.9.9
git -C "$REPO" checkout -q main

echo "half done" > "$REPO/stray-file.txt"
expect_not "release: dirty tree refused"             release 9.9.9
expect     "release: … message names the file"       contains "$OUT" "stray-file.txt"
expect_not "release: … before building"              contains "$OUT" "building"
expect     "release: … Info.plist unchanged"         plist_unchanged
rm "$REPO/stray-file.txt"

# A release is signed by team T748B76PPL only: another TEAM_ID, or SIGN_IDENTITY, is refused.
# release_with <NAME=value>: as release 9.9.9, with that variable set.
release_with() {
  local status=0
  OUT="$(cd "$REPO" && env "$1" RELEASE_CHECKS_ONLY=1 scripts/release.sh 9.9.9 2>&1)" || status=$?
  return "$status"
}
expect_not "release: another TEAM_ID refused"        release_with TEAM_ID=XXXXXXXXXX
expect     "release: … message names the team"       contains "$OUT" "team T748B76PPL only"
expect     "release: … and the tree stays clean"     clean_tree
expect_not "release: SIGN_IDENTITY refused"          release_with SIGN_IDENTITY=-
expect     "release: … message names SIGN_IDENTITY"  contains "$OUT" "SIGN_IDENTITY is for"
expect     "release: … and the tree stays clean"     clean_tree
expect     "release: TEAM_ID=T748B76PPL accepted"    release_with TEAM_ID=T748B76PPL

# The guard before the release commit: HEAD is where step 1 saw it, and the only change is the bump.
if [[ -f "$ROOT/scripts/lib/release-guard.sh" ]]; then
  source "$ROOT/scripts/lib/release-guard.sh"
  START="$(git -C "$REPO" rev-parse HEAD)"
  guard() { local status=0; OUT="$(cd "$REPO" && release_commit_guard "$START" 2>&1)" || status=$?; return "$status"; }
  bump() { set_plist_version "$REPO/Resources/Info.plist" 9.9.9 2; }
  reset_repo() { git -C "$REPO" reset -q --hard "$START"; git -C "$REPO" clean -qfd; }

  bump
  expect     "guard: only the bump passes"            guard
  echo "# edited during the build" >> "$REPO/scripts/env.sh"
  expect_not "guard: another edited file refused"     guard
  expect     "guard: … message names it"              contains "$OUT" "scripts/env.sh"
  reset_repo; bump
  echo "new" > "$REPO/new-file.txt"
  expect_not "guard: a new file refused"              guard
  reset_repo
  expect_not "guard: no bump refused"                 guard
  # "unbumped": after the tests, before the version bump, there must be no change at all.
  unbumped() { local status=0; OUT="$(cd "$REPO" && release_commit_guard "$START" unbumped 2>&1)" || status=$?; return "$status"; }
  expect     "guard unbumped: a clean tree passes"    unbumped
  echo "new" > "$REPO/new-file.txt"
  expect_not "guard unbumped: a new file refused"     unbumped
  expect     "guard unbumped: … message names it"     contains "$OUT" "new-file.txt"
  reset_repo; bump
  expect_not "guard unbumped: the bump refused too"   unbumped
  reset_repo
  git -C "$REPO" -c user.name=test -c user.email=test@invalid commit -q --allow-empty -m "made during the run"
  bump
  expect_not "guard: HEAD moved refused"              guard
  expect     "guard: … message says HEAD moved"       contains "$OUT" "HEAD"
  reset_repo
else
  bad "guard: scripts/lib/release-guard.sh exists"
fi

# Running a version again whose "Release <version>" commit is HEAD but has no tag (a run that failed
# in step 7 or 8): the commands that finish it, not "not higher"; dist/'s files stay.
if [[ -f "$ROOT/scripts/lib/release-guard.sh" ]]; then
  set_plist_version "$REPO/Resources/Info.plist" 9.9.9 2
  git -C "$REPO" -c user.name=test -c user.email=test@invalid commit -q -m "Release 9.9.9" -- Resources/Info.plist
  mkdir -p "$REPO/dist"
  for file in Singularity-9.9.9.zip appcast.xml release-notes.md; do echo "from the failed run" > "$REPO/dist/$file"; done
  expect_not "re-run: refused"                          release 9.9.9
  expect_not "re-run: … not \"not higher\""             contains "$OUT" "not higher"
  expect_not "re-run: … not \"Nothing was pushed\""     contains "$OUT" "Nothing was pushed"
  expect     "re-run: … step 7: push"                   contains "$OUT" "7. git push origin main"
  expect     "re-run: … step 8: create the draft"       contains "$OUT" "gh release create v9.9.9"
  expect     "re-run: … with absolute dist/ paths"      contains "$OUT" "\"$REPO/dist/Singularity-9.9.9.zip\" \"$REPO/dist/appcast.xml\""
  expect     "re-run: … notes by absolute path"         contains "$OUT" "--notes-file \"$REPO/dist/release-notes.md\""
  expect     "re-run: … step 8: publish"                contains "$OUT" "--draft=false --latest"
  expect     "re-run: … the way back"                   contains "$OUT" "git reset --hard origin/main"
  expect_not "re-run: … no missing-file warning"        contains "$OUT" "missing"
  expect     "re-run: … dist/ files kept"               [ -f "$REPO/dist/Singularity-9.9.9.zip" -a -f "$REPO/dist/appcast.xml" -a -f "$REPO/dist/release-notes.md" ]
  expect     "re-run: … tree clean"                     clean_tree
  # Pushed already (origin/main, as this clone saw it, is the release commit): from step 8 on.
  git -C "$REPO" update-ref refs/remotes/origin/main HEAD
  expect_not "re-run pushed: refused"                   release 9.9.9
  expect     "re-run pushed: … from step 8"             contains "$OUT" "from step 8"
  expect_not "re-run pushed: … no push"                 contains "$OUT" "git push origin main"
  expect_not "re-run pushed: … no way back"             contains "$OUT" "git reset --hard"
  git -C "$REPO" update-ref -d refs/remotes/origin/main
  rm "$REPO/dist/appcast.xml"
  expect_not "re-run, a file missing: refused"          release 9.9.9
  expect     "re-run, a file missing: … says which"     contains "$OUT" "$REPO/dist/appcast.xml is missing"
  # A tag means it was released: then the version is simply not higher.
  git -C "$REPO" tag v9.9.9
  expect_not "re-run tagged: refused"                   release 9.9.9
  expect     "re-run tagged: … not higher"              contains "$OUT" "not higher"
  git -C "$REPO" tag -d v9.9.9 >/dev/null
  # Another subject is not a release commit.
  git -C "$REPO" -c user.name=test -c user.email=test@invalid commit -q --allow-empty -m "Release 9.9.9 notes"
  expect_not "re-run other subject: refused"            release 9.9.9
  expect     "re-run other subject: … not higher"       contains "$OUT" "not higher"
  rm -rf "$REPO/dist"
  reset_repo
  expect     "re-run: the repository is back"           plist_unchanged
fi

# Closing the terminal (SIGHUP) or SIGTERM after the version bump restores Info.plist and removes the
# dist/ files of the version that was never released.
# RELEASE_TEST_HOLD_AFTER_BUMP=1 makes the script bump, then wait (10 s at most) instead of going on.
# RELEASE_CHECKS_ONLY=1 is set too: a script without the hook stops at its local checks.
for signal in TERM:143 HUP:129; do
  expected_status="${signal#*:}"; signal="${signal%:*}"
  ( cd "$REPO" && RELEASE_CHECKS_ONLY=1 RELEASE_TEST_HOLD_AFTER_BUMP=1 exec scripts/release.sh 9.9.9 ) \
    >"$TMP/hold.log" 2>&1 &
  pid=$!
  for _ in $(seq 50); do
    grep -q "holding" "$TMP/hold.log" 2>/dev/null && break
    sleep 0.1
  done
  expect "signal $signal: the script bumped and held" grep -q "holding" "$TMP/hold.log"
  expect "signal $signal: the dist/ stand-ins exist"     [ -f "$REPO/dist/Singularity-9.9.9.zip" -a -f "$REPO/dist/appcast.xml" -a -f "$REPO/dist/release-notes.md" ]
  kill -"$signal" "$pid" 2>/dev/null || true
  status=0; wait "$pid" || status=$?
  expect "signal $signal: exits with $expected_status"            [ "$status" -eq "$expected_status" ]
  expect "signal $signal: Info.plist restored"          plist_unchanged
  expect "signal $signal: tree clean"                   clean_tree
  expect "signal $signal: says nothing was published"   grep -q "Nothing was pushed or published" "$TMP/hold.log"
  expect_not "signal $signal: dist/ zip removed"        [ -e "$REPO/dist/Singularity-9.9.9.zip" ]
  expect_not "signal $signal: dist/ appcast.xml removed" [ -e "$REPO/dist/appcast.xml" ]
  expect_not "signal $signal: dist/ notes removed"      [ -e "$REPO/dist/release-notes.md" ]
done

# --scratch needs its three variables; checked before anything is built.
expect_not "release: --scratch without its variables refused" release 9.9.9 --scratch "$TMP/scratch"
expect     "release: … message names SCRATCH_KEY_FILE" contains "$OUT" "SCRATCH_KEY_FILE"
expect_not "release: … nothing written"              [ -e "$TMP/scratch" ]
expect     "release: … Info.plist unchanged"         plist_unchanged

echo
if (( failures )); then echo "$failures release test(s) failed"; exit 1; fi
echo "release tests passed"
