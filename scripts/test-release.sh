#!/usr/bin/env bash
# Offline tests for the release scripts: scripts/lib/version.sh, scripts/appcast.sh and the checks
# at the start of scripts/release.sh. No build, no network, no keychain.
#
# release.sh only ever runs here in a throwaway git repository under /private/tmp (a copy of the
# scripts and Resources/Info.plist, on a branch named main), and always with RELEASE_CHECKS_ONLY=1,
# which stops it right after its local checks. So even a broken check can never reach a build,
# the network, GitHub or the keychain.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Checked first: bash 3.2 exits with status 0 when `source` finds no file and an EXIT trap is set.
for file in scripts/lib/version.sh scripts/appcast.sh scripts/release.sh; do
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
cp "$ROOT/scripts/lib/version.sh" "$REPO/scripts/lib/"
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

# --scratch needs its three variables; checked before anything is built.
expect_not "release: --scratch without its variables refused" release 9.9.9 --scratch "$TMP/scratch"
expect     "release: … message names SCRATCH_KEY_FILE" contains "$OUT" "SCRATCH_KEY_FILE"
expect_not "release: … nothing written"              [ -e "$TMP/scratch" ]
expect     "release: … Info.plist unchanged"         plist_unchanged

echo
if (( failures )); then echo "$failures release test(s) failed"; exit 1; fi
echo "release tests passed"
