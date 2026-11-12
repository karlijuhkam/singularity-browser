#!/usr/bin/env bash
#
# The release command. One command bumps the version, builds a universal (Apple Silicon + Intel)
# app, signs it, writes Sparkle's update feed and publishes everything as a GitHub release, from
# which installed copies update themselves.
#
#   scripts/release.sh <version> [--notes-file <path>] [--yes]   # a release, e.g. scripts/release.sh 0.2.0
#   scripts/release.sh --skip-notarize                   # a signed local build of the current
#                                                        # version in dist/; publishes nothing
#   scripts/release.sh <version> --scratch <dir>         # a throwaway update-test bundle (below)
#
#   --notes-file <path>  the release notes, instead of editing them in $EDITOR (step 6)
#   --yes                publish without the "Publish? [y/N]" question (step 6); a release started
#                        without a terminal is refused unless it has --yes
#
# A release, step by step (failure messages refer to these numbers):
#   1. Checks, before anything changes: the version is N.N.N; on main; no uncommitted changes; the
#      version is higher than Resources/Info.plist's; the tag v<version> is free; origin is
#      github.com/<REPO>; main is in sync with origin/main; gh is logged in, its account may push
#      to the repository and the repository is public (installed copies download from it without
#      logging in); `git push --dry-run` works; when commit.gpgsign is on, git can sign a commit;
#      the update key in the keychain matches PUBLIC_ED_KEY; a signing certificate of team TEAM_ID
#      exists. A leftover draft release of this version (from a failed run) is deleted; a
#      published one stops the release.
#   2. scripts/test.sh passes; then nothing in the repository may have changed.
#   3. Resources/Info.plist gets the new version and the next build number. Any failure from here
#      until step 7 restores it, and removes the zip, appcast.xml and notes this run wrote.
#   4. Build, assemble, stamp the feed URL and the public update key into the bundle's Info.plist
#      (only release bundles update; the checked-in Info.plist has neither), sign; again nothing
#      but the version bump may have changed. Notarized and stapled when the team has a Developer
#      ID certificate and the notary profile works; otherwise signed with the team's Apple
#      Development certificate and marked "not notarized".
#   5. dist/Singularity-<version>.zip, signed with the update key; dist/Singularity.app is removed,
#      so no second stamped copy of the app lies around.
#   6. Release notes: the commit subjects since the previous tag, opened in $EDITOR to trim
#      (--notes-file skips that). They become the GitHub release text and what Sparkle shows.
#      Then dist/appcast.xml, Sparkle's feed with this one release. Last, the script shows the
#      version, build, whether it is notarized, the signing certificate and the notes, and asks
#      "Publish? [y/N]" in the terminal; anything but y stops the release. --yes publishes without
#      asking; without a terminal (started by another program) the release needs --yes.
#   7. Commit "Release <version>" and push main (no tag).
#   8. A draft GitHub release for that commit gets the zip and appcast.xml, then is published as
#      "latest". Publishing creates the tag, so installed copies only ever see complete releases.
#   9. Fetch the new tag; print the release's address.
#
# A failure in step 7, 8 or 9 prints the commands that finish the release by hand (with the files in
# dist/, which are kept from step 7 on), and, while the commit is not pushed, how to drop it instead
# (git reset --hard origin/main). Running `release.sh <version>` again for a version whose
# "Release <version>" commit is HEAD but which has no tag prints the same commands and stops.
#
# --scratch <dir> builds a bundle for testing updates offline, with a throwaway key and a local feed.
# It needs SCRATCH_PUBLIC_KEY and SCRATCH_KEY_FILE (a throwaway key pair: scripts/make-scratch-key.sh)
# and SCRATCH_FEED_URL (where the test's appcast.xml will be served; the zip is expected next to it).
# Sparkle accepts only http or https there, never file://: serve the folder on 127.0.0.1, e.g.
# `python3 -m http.server 8765 --bind 127.0.0.1 --directory <dir>` and SCRATCH_FEED_URL=http://127.0.0.1:8765/appcast.xml
# (the app's Info.plist already allows local-network http). It writes <dir>/Singularity.app, <dir>/Singularity-<version>.zip and
# <dir>/appcast.xml. The version goes into the bundle only (CFBundleVersion = the version too, which
# Sparkle compares part by part), and the bundle is marked SGUpdateTestBundle. Nothing touches git,
# GitHub, the keychain's update key or notarization, and Resources/Info.plist stays as it is.
#
# Environment:
#   TEAM_ID         Apple Developer team whose certificates sign (default: T748B76PPL, Karli Juhkam).
#                   Only that team's certificates are used. Another team only for --skip-notarize and
#                   --scratch: a release is always signed by T748B76PPL.
#   SIGN_IDENTITY   explicit codesign identity, for --skip-notarize and --scratch only ("-" is ad-hoc).
#                   Default: the team's "Developer ID Application", then its "Apple Development"
#                   (--scratch: its "Apple Development"). A release always uses the team's certificates.
#   NOTARY_PROFILE  notarytool keychain profile (default: singularity-notary). Create it once with:
#                   xcrun notarytool store-credentials singularity-notary --apple-id <you> --team-id <team>
#   RELEASE_CHECKS_ONLY=1
#                   stop right after the checks that need nothing but this folder (the version, the
#                   branch, uncommitted changes, an unfinished earlier run of this version, the
#                   version is higher, the tag is free locally; with
#                   --scratch: its variables). Nothing reaches the network, gh, the keychain or a
#                   build. scripts/test-release.sh uses it.
#   RELEASE_TEST_HOLD_AFTER_BUMP=1
#                   for scripts/test-release.sh only: after the local checks, bump Resources/Info.plist
#                   as step 3 does and write stand-ins for dist/'s zip, appcast.xml and notes, then
#                   wait up to 10 s for the test to stop the script with a signal (the exit trap must
#                   put Info.plist back and remove the stand-ins). Never builds or reaches the network.
#
# One-time setup for notarization: create a "Developer ID Application" certificate at
# developer.apple.com → Certificates, IDs & Profiles → "+", download it and double-click to install.

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/scripts/lib/version.sh"
source "$ROOT/scripts/lib/release-guard.sh"
source "$ROOT/scripts/lib/release-helpers.sh"

# Baked into every installed copy for good: changing these strands the copies already out there.
REPO="karlijuhkam/singularity-browser"
FEED_URL="https://github.com/$REPO/releases/latest/download/appcast.xml"
# The public half of the update key (Sparkle's generate_keys prints it). Installed copies accept only
# updates signed with the matching private key, which stays in the owner's login keychain.
PUBLIC_ED_KEY=""
# The only team that may sign a release (this Mac also holds another company's certificates).
RELEASE_TEAM="T748B76PPL"
TEAM_ID="${TEAM_ID:-$RELEASE_TEAM}"

NOTARY_PROFILE="${NOTARY_PROFILE:-singularity-notary}"
DIST="$ROOT/dist"
PLIST="$ROOT/Resources/Info.plist"
SPARKLE_BIN="$ROOT/.build/artifacts/sparkle/Sparkle/bin"
PB=/usr/libexec/PlistBuddy

fail() { echo "error: $*" >&2; exit 1; }
usage() {
  echo "usage: scripts/release.sh <version> [--notes-file <path>] [--yes]   (a release, e.g. 0.2.0)" >&2
  echo "       scripts/release.sh --skip-notarize                   (a local build; publishes nothing)" >&2
  echo "       scripts/release.sh <version> --scratch <dir>         (an update-test bundle)" >&2
  exit 2
}
# Paths given on the command line are relative to where the script was started, not to $ROOT.
absolute() { if [[ "$1" == /* ]]; then echo "$1"; else echo "$PWD/$1"; fi; }

# ---- arguments ----------------------------------------------------------------------------------
MODE=release            # release | skip-notarize | scratch
VERSION=""
NOTES_FILE=""
SCRATCH_DIR=""
ASSUME_YES=0            # 1: --yes, publish without asking
while (( $# )); do
  case "$1" in
    --skip-notarize) [[ "$MODE" == release ]] || usage; MODE=skip-notarize ;;
    --scratch)       [[ "$MODE" == release && $# -ge 2 ]] || usage; MODE=scratch; SCRATCH_DIR="$2"; shift ;;
    --notes-file)    [[ $# -ge 2 ]] || usage; NOTES_FILE="$2"; shift ;;
    --yes)           ASSUME_YES=1 ;;
    -h|--help)       usage ;;
    -*)              usage ;;
    *)               [[ -z "$VERSION" ]] || usage; VERSION="$1" ;;
  esac
  shift
done
[[ -n "$NOTES_FILE" ]] && NOTES_FILE="$(absolute "$NOTES_FILE")"
[[ -n "$SCRATCH_DIR" ]] && SCRATCH_DIR="$(absolute "$SCRATCH_DIR")"
[[ -n "${SCRATCH_KEY_FILE:-}" ]] && SCRATCH_KEY_FILE="$(absolute "$SCRATCH_KEY_FILE")"
cd "$ROOT"
if [[ "$MODE" == skip-notarize ]]; then
  # As before: the version in Resources/Info.plist, unchanged.
  [[ -z "$VERSION" && -z "$NOTES_FILE" ]] || usage
  VERSION="$($PB -c 'Print CFBundleShortVersionString' "$PLIST")"
else
  [[ -n "$VERSION" ]] || usage
  valid_version "$VERSION" || fail "\"$VERSION\" is not a version: use three numbers, like 0.2.0."
fi
[[ -z "$NOTES_FILE" || -r "$NOTES_FILE" ]] || fail "cannot read the notes file $NOTES_FILE."
[[ "$MODE" == release || "$ASSUME_YES" == 0 ]] || usage   # only a release asks before publishing

# ---- what happens on failure --------------------------------------------------------------------
# Success is a flag set right before each intended exit, not read from $?: bash 3.2 (macOS's
# /bin/bash) runs the EXIT trap with $? = 0 when the script is ended by a signal such as SIGHUP
# (the terminal was closed). The signal traps also give such an ending the usual non-zero status.
STEP=1
SUCCEEDED=0        # 1 right before every successful exit
RESTORE_PLIST=0    # 1 between the version bump (step 3) and the release commit (step 7)
COMMITTED=0        # 1 once the "Release <version>" commit exists
STAMPED_APP=""     # a release's dist/Singularity.app (it carries the live feed URL and key)
RELEASE_FILES=()   # the zip, appcast.xml and notes this release wrote in dist/ (see will_write)
TOLD=0             # 1 when the reason for stopping was already printed in full
TEMP_DIR="$(mktemp -d /private/tmp/sg-release-XXXX)"

# will_write <file>: a file in dist/ that this release is about to write. If the release stops before
# its commit, the version was never released and the exit trap removes the file again.
will_write() {
  if [[ "$MODE" == release ]]; then RELEASE_FILES+=("$1"); fi
}

# finish_by_hand <step>: prints the commands that finish a release whose commit exists, from <step>
# (7, 8 or 9) on, and, while the commit may not be pushed yet, how to drop it instead.
finish_by_hand() {
  if (( $1 <= 7 )); then echo "  7. git push origin main" >&2; fi
  if (( $1 <= 8 )); then
    echo "  8. (if a draft v$VERSION exists: gh release delete v$VERSION --repo $REPO --yes)" >&2
    echo "     gh release create v$VERSION --repo $REPO --draft --target $(git rev-parse HEAD) --title \"Singularity $VERSION\" --notes-file \"$DIST/release-notes.md\" \"$DIST/Singularity-$VERSION.zip\" \"$DIST/appcast.xml\"" >&2
    echo "     gh release edit v$VERSION --repo $REPO --draft=false --latest" >&2
  fi
  echo "  9. git fetch --tags" >&2
  if (( $1 <= 7 )); then
    echo "Or drop the release commit, as long as it is not pushed, and start again: git reset --hard origin/main" >&2
  fi
}

on_exit() {
  rm -rf "$TEMP_DIR"
  (( SUCCEEDED )) && return 0
  if [[ -n "$STAMPED_APP" ]]; then
    rm -rf "$STAMPED_APP"   # no stamped app may stay behind from a release that did not finish
  fi
  if (( RESTORE_PLIST )); then
    git checkout -- Resources/Info.plist && echo "Resources/Info.plist is restored." >&2
  fi
  [[ "$MODE" == release ]] || return 0
  (( TOLD )) && return 0
  if (( ! COMMITTED )); then
    # Never released, so its zip, feed and notes go too. From step 7 on they are kept: the
    # commands that finish the release by hand need them.
    rm -f ${RELEASE_FILES[@]+"${RELEASE_FILES[@]}"}
    echo "The release stopped at step $STEP. Nothing was pushed or published." >&2
  else
    echo "The release stopped at step $STEP. Repeat by hand from there:" >&2
    finish_by_hand "$STEP"
  fi
}
trap on_exit EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

# ---- checks that need nothing but this folder ---------------------------------------------------
CURRENT_VERSION="$($PB -c 'Print CFBundleShortVersionString' "$PLIST")"
CURRENT_BUILD="$($PB -c 'Print CFBundleVersion' "$PLIST")"
if [[ "$MODE" == release ]]; then
  echo "→ step 1: checks"
  BRANCH="$(git symbolic-ref --short -q HEAD || true)"
  [[ "$BRANCH" == main ]] || fail "releases are made from main (this is ${BRANCH:-a detached HEAD})."
  CHANGES="$(git status --porcelain)"
  [[ -z "$CHANGES" ]] || fail "there are uncommitted changes; commit or remove them first:
$CHANGES"
  # Running it again after a failure in step 7 or 8: the release commit is HEAD, so Info.plist already
  # has this version and the run would only say "not higher". Say how to finish it instead.
  if [[ "$VERSION" == "$CURRENT_VERSION" && "$(git log -1 --no-show-signature --format=%s)" == "Release $VERSION" ]] \
     && ! git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null; then
    FROM=7   # origin/main as this clone last saw it: already the release commit means it was pushed
    [[ "$(git rev-parse -q --verify origin/main || true)" == "$(git rev-parse HEAD)" ]] && FROM=8
    echo "error: $VERSION is committed (\"Release $VERSION\" is HEAD) but not published (there is no tag v$VERSION)." >&2
    echo "Finish it by hand from step $FROM (if https://github.com/$REPO/releases/tag/v$VERSION is already published, only step 9 is left):" >&2
    finish_by_hand "$FROM"
    for file in "$DIST/release-notes.md" "$DIST/Singularity-$VERSION.zip" "$DIST/appcast.xml"; do
      [[ -f "$file" ]] || echo "warning: $file is missing, and step 8 needs it. If the commit is not pushed, drop it and release again; if it is, release the next version." >&2
    done
    TOLD=1
    exit 1
  fi
  version_gt "$VERSION" "$CURRENT_VERSION" \
    || fail "$VERSION is not higher than the current version $CURRENT_VERSION (Resources/Info.plist)."
  [[ "$CURRENT_BUILD" =~ ^[0-9]+$ ]] || fail "CFBundleVersion in Resources/Info.plist is not a whole number: $CURRENT_BUILD"
  ! git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null || fail "the tag v$VERSION already exists."
  [[ "$TEAM_ID" == "$RELEASE_TEAM" ]] || fail "a release is signed by team $RELEASE_TEAM only (TEAM_ID is $TEAM_ID)."
  [[ -z "${SIGN_IDENTITY:-}" ]] || fail "SIGN_IDENTITY is for --skip-notarize and --scratch; a release is signed with team $RELEASE_TEAM's certificates."
  START_HEAD="$(git rev-parse HEAD)"   # the release commit must sit right on top of this (step 7)
elif [[ "$MODE" == scratch ]]; then
  for name in SCRATCH_FEED_URL SCRATCH_PUBLIC_KEY SCRATCH_KEY_FILE; do
    [[ -n "${!name:-}" ]] || fail "--scratch needs SCRATCH_FEED_URL, SCRATCH_PUBLIC_KEY and SCRATCH_KEY_FILE ($name is not set).
       A throwaway key pair: scripts/make-scratch-key.sh <dir>"
  done
  [[ -r "$SCRATCH_KEY_FILE" ]] || fail "cannot read SCRATCH_KEY_FILE ($SCRATCH_KEY_FILE)."
fi

# Step 3's version bump; also called by the test hook below.
bump_version() {
  BUILD=$((CURRENT_BUILD + 1))
  RESTORE_PLIST=1
  set_plist_version "$PLIST" "$VERSION" "$BUILD"
}

if [[ "${RELEASE_TEST_HOLD_AFTER_BUMP:-}" == 1 && "$MODE" == release ]]; then
  bump_version
  # Stand-ins for the files steps 5 and 6 write, which the exit trap must remove as well.
  mkdir -p "$DIST"
  for file in "$DIST/Singularity-$VERSION.zip" "$DIST/appcast.xml" "$DIST/release-notes.md"; do
    will_write "$file"
    echo "test stand-in" >"$file"
  done
  echo "holding after the bump (RELEASE_TEST_HOLD_AFTER_BUMP=1)"
  for _ in $(seq 100); do sleep 0.1; done
  fail "RELEASE_TEST_HOLD_AFTER_BUMP: no signal came within 10 s."
fi
if [[ "${RELEASE_CHECKS_ONLY:-}" == 1 ]]; then
  echo "✓ local checks passed; stopping here (RELEASE_CHECKS_ONLY=1)"
  SUCCEEDED=1
  exit 0
fi

# ---- the rest of step 1: checks that reach the network, GitHub and the keychain -----------------
if [[ "$MODE" == release && -z "$PUBLIC_ED_KEY" ]]; then
  fail "PUBLIC_ED_KEY in scripts/release.sh is empty: there is no update key yet.
       Create it once with Sparkle's generate_keys and put the public key it prints there."
fi

source "$ROOT/scripts/env.sh"

# Sparkle's command-line tools come with the Sparkle package (downloaded by SwiftPM).
sparkle_tool() {
  if [[ ! -x "$SPARKLE_BIN/$1" ]]; then
    swift package resolve >/dev/null
    [[ -x "$SPARKLE_BIN/$1" ]] || fail "Sparkle's $1 not found in $SPARKLE_BIN."
  fi
  echo "$SPARKLE_BIN/$1"
}

if [[ "$MODE" == release ]]; then
  # Steps 7 and 8 push to origin and publish on $REPO: check now that both can work. All of these
  # only read.
  ORIGIN_URL="$(git remote get-url origin 2>/dev/null)" \
    || fail "there is no remote named origin: git remote add origin https://github.com/$REPO.git"
  origin_is_repo "$ORIGIN_URL" "$REPO" \
    || fail "origin is $ORIGIN_URL, not github.com/$REPO: git remote set-url origin https://github.com/$REPO.git"
  git fetch -q origin main || fail "could not fetch origin main."
  [[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] \
    || fail "main is not the same commit as origin/main; pull or push first."
  REMOTE_TAG="$(git ls-remote --tags origin "refs/tags/v$VERSION")" || fail "could not list origin's tags."
  [[ -z "$REMOTE_TAG" ]] || fail "the tag v$VERSION already exists on origin."
  gh auth status >/dev/null 2>&1 || fail "gh is not logged in: gh auth login"
  # "true public" when gh's account may push and anyone may download (a private repository would
  # publish without an error, while every installed copy got "not found" for the feed).
  REPO_ACCESS="$(gh api "repos/$REPO" --jq '"\(.permissions.push) \(.visibility)"' 2>/dev/null)" \
    || fail "gh cannot see the repository $REPO: log in with an account that has access (gh auth login)."
  [[ "${REPO_ACCESS% *}" == true ]] \
    || fail "the account gh is logged in with cannot push to $REPO: gh auth login with one that can."
  [[ "${REPO_ACCESS#* }" == public ]] \
    || fail "$REPO is not public, so installed copies could not download updates: make it public first."
  PUSH_TEST="$(git push --dry-run origin main 2>&1)" \
    || fail "git cannot push to origin (git push --dry-run origin main failed); fix the credentials first:
$PUSH_TEST"
  # With commit.gpgsign on, step 7's commit is signed: try it now, not after a long build. commit-tree
  # writes a loose commit object that no branch or tag points at, so nothing in the repository changes.
  if [[ "$(git config --type=bool --get commit.gpgsign || true)" == true ]]; then
    git commit-tree -S -m "signing test" "$(git rev-parse 'HEAD^{tree}')" >/dev/null 2>&1 \
      || fail "commit.gpgsign is on, but git cannot sign a commit: fix the signing key (or switch commit.gpgsign off) first."
  fi
  GENERATE_KEYS="$(sparkle_tool generate_keys)"
  # -p only prints the public key of the key pair already in the login keychain; it creates nothing.
  KEYCHAIN_KEY="$("$GENERATE_KEYS" -p 2>/dev/null | tr -d '[:space:]')" \
    || fail "no update key in the login keychain (Sparkle's generate_keys -p found none)."
  [[ "$KEYCHAIN_KEY" == "$PUBLIC_ED_KEY" ]] \
    || fail "the update key in the keychain ($KEYCHAIN_KEY) is not PUBLIC_ED_KEY ($PUBLIC_ED_KEY)."
fi

# ---- signing identity ---------------------------------------------------------------------------
# Only certificates of TEAM_ID are considered (the team shown as Singularity's developer); this Mac
# also holds certificates of another company's team, which must never sign Singularity.
# Identities are picked by SHA-1 fingerprint, not by name: a keychain can hold several
# certificates with the same name, and then codesign refuses an ambiguous name.
# Prints "fingerprint<TAB>team<TAB>name" for every valid code-signing identity.
identities() {
  security find-identity -v -p codesigning | awk '$2 ~ /^[0-9A-F]{40}$/ { print $2 }' | while read -r hash; do
    local pem team name
    pem="$(security find-certificate -a -Z -p | awk -v h="$hash" 'BEGIN { RS = "SHA-1 hash: " } index($0, h) == 1' \
           | sed -n '/BEGIN CERT/,/END CERT/p')"
    # No `exit` in these awks: stopping early would kill openssl with SIGPIPE (see first_identity).
    team="$(printf '%s\n' "$pem" | openssl x509 -noout -subject -nameopt multiline 2>/dev/null \
            | awk -F' = ' '!seen && /organizationalUnitName/ { print $2; seen = 1 }')"
    name="$(printf '%s\n' "$pem" | openssl x509 -noout -subject -nameopt multiline 2>/dev/null \
            | awk -F' = ' '!seen && /commonName/ { print $2; seen = 1 }')"
    printf '%s\t%s\t%s\n' "$hash" "$team" "$name"
  done
}
# First identity of TEAM_ID whose name starts with $1; prints "fingerprint<TAB>name".
identity_in_team() {
  identities | first_identity "$TEAM_ID" "$1"
}

NOTARIZE=0        # 1: notarize and staple (a release with a Developer ID and a working notary profile)
NOT_NOTARIZED=0   # 1: a release signed for development only; said in the terminal and in the notes
FOUND=""
if [[ "$MODE" == release ]]; then
  FOUND="$(identity_in_team 'Developer ID Application')"
  if [[ -n "$FOUND" ]] && xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    NOTARIZE=1
  else
    [[ -n "$FOUND" ]] && echo "→ the notary profile \"$NOTARY_PROFILE\" does not work; not notarizing"
    FOUND="$(identity_in_team 'Apple Development')"
    NOT_NOTARIZED=1
  fi
  [[ -n "$FOUND" ]] || fail "no signing certificate of team $TEAM_ID in the keychain."
elif [[ -z "${SIGN_IDENTITY:-}" ]]; then
  # --skip-notarize: Developer ID first, as before; --scratch: Apple Development.
  [[ "$MODE" == skip-notarize ]] && FOUND="$(identity_in_team 'Developer ID Application')"
  if [[ -z "$FOUND" ]]; then
    FOUND="$(identity_in_team 'Apple Development')"
    if [[ -n "$FOUND" && "$MODE" == skip-notarize ]]; then
      echo "→ no Developer ID certificate in team $TEAM_ID; signing for local testing only"
    fi
  fi
  [[ -n "$FOUND" ]] || fail "no signing certificate of team $TEAM_ID in the keychain."
fi
if [[ -n "$FOUND" ]]; then
  IDENTITY="${FOUND%%$'\t'*}"
  IDENTITY_NAME="${FOUND#*$'\t'}"
else
  IDENTITY="$SIGN_IDENTITY"; IDENTITY_NAME="$SIGN_IDENTITY"
fi

# The last check changes something on GitHub, so it comes after all the others: a draft release is
# what a run that failed in step 8 leaves behind (installed copies never see drafts).
if [[ "$MODE" == release ]]; then
  if DRAFT="$(gh release view "v$VERSION" --repo "$REPO" --json isDraft --jq .isDraft 2>/dev/null)"; then
    [[ "$DRAFT" == true ]] || fail "a published release v$VERSION already exists."
    echo "→ deleting the draft release v$VERSION left by an earlier run"
    gh release delete "v$VERSION" --repo "$REPO" --yes
  fi
fi

# ---- step 2: tests ------------------------------------------------------------------------------
if [[ "$MODE" == release ]]; then
  STEP=2; echo "→ step 2: scripts/test.sh"
  "$ROOT/scripts/test.sh"
  release_commit_guard "$START_HEAD" unbumped || fail "the repository changed while the tests ran."
fi

# ---- step 3: version ----------------------------------------------------------------------------
BUILD="$CURRENT_BUILD"
if [[ "$MODE" == release ]]; then
  STEP=3
  bump_version
  echo "→ step 3: version $VERSION, build $BUILD"
elif [[ "$MODE" == scratch ]]; then
  BUILD="$VERSION"
fi

# ---- step 4: build ------------------------------------------------------------------------------
STEP=4
if [[ "$MODE" == scratch ]]; then
  mkdir -p "$SCRATCH_DIR"
  OUT_DIR="$(cd "$SCRATCH_DIR" && pwd)"
else
  OUT_DIR="$DIST"
fi
APP="$OUT_DIR/Singularity.app"
ZIP="$OUT_DIR/Singularity-$VERSION.zip"

"$ROOT/scripts/fetch-bun.sh"

echo "→ step 4: building release (universal)"
ARCH_FLAGS=(--arch arm64 --arch x86_64)
if ! swift build -c release "${ARCH_FLAGS[@]}" --product Singularity >/dev/null \
   || ! swift build -c release "${ARCH_FLAGS[@]}" --product singularity-mcp >/dev/null; then
  if [[ "$MODE" == release ]]; then
    fail "the universal (Apple Silicon + Intel) build failed; a release must run on both."
  fi
  echo "warning: universal build failed; building for Apple Silicon only" >&2
  ARCH_FLAGS=(--arch arm64)
  swift build -c release "${ARCH_FLAGS[@]}" --product Singularity
  swift build -c release "${ARCH_FLAGS[@]}" --product singularity-mcp
fi
BIN_DIR="$(swift build -c release "${ARCH_FLAGS[@]}" --show-bin-path)"

echo "→ assembling $APP"
if [[ "$MODE" == release ]]; then STAMPED_APP="$APP"; fi   # removed again if the release fails
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers"
cp "$BIN_DIR/Singularity" "$BIN_DIR/singularity-mcp" "$APP/Contents/MacOS/"
cp "$ROOT/Vendor/bun/bun" "$APP/Contents/Helpers/bun"
cp "$PLIST" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$ROOT"/Resources/*.png "$APP/Contents/Resources/"
cp -R "$ROOT/Resources/plugin-host" "$APP/Contents/Resources/"   # plugins' host.ts
# Ready-made plugins (every folder of Plugins/ except the template) and the authoring guide with the
# template, for the welcome flow. Copied before signing, so the signature seals them.
RSYNC_SKIP=(--exclude node_modules --exclude .git --exclude .DS_Store)
mkdir -p "$APP/Contents/Resources/Plugins" "$APP/Contents/Resources/plugin-guide"
for plugin in "$ROOT"/Plugins/*/; do
  [[ "$(basename "$plugin")" == template ]] && continue
  rsync -a "${RSYNC_SKIP[@]}" "$plugin" "$APP/Contents/Resources/Plugins/$(basename "$plugin")/"
done
cp "$ROOT/docs/plugins/AUTHORING.md" "$APP/Contents/Resources/plugin-guide/"
rsync -a "${RSYNC_SKIP[@]}" "$ROOT/Plugins/template/" "$APP/Contents/Resources/plugin-guide/template/"
cp "$ROOT/Resources/THIRD-PARTY-NOTICES.txt" "$APP/Contents/Resources/"   # licences of bundled software
for bundle in "$BIN_DIR"/*.bundle; do
  [[ -e "$bundle" ]] && cp -R "$bundle" "$APP/Contents/Resources/"
done
echo "  architectures: $(lipo -archs "$APP/Contents/MacOS/Singularity")"

# Stamp the updater's keys into the bundle's own Info.plist (before signing: the signature seals it).
# Only bundles with both keys create an updater; --skip-notarize builds get none.
# plutil -replace adds a key or replaces it, and takes the value as one argument.
BUNDLE_PLIST="$APP/Contents/Info.plist"
if [[ "$MODE" == release ]]; then
  plutil -replace SUFeedURL -string "$FEED_URL" "$BUNDLE_PLIST"
  plutil -replace SUPublicEDKey -string "$PUBLIC_ED_KEY" "$BUNDLE_PLIST"
elif [[ "$MODE" == scratch ]]; then
  set_plist_version "$BUNDLE_PLIST" "$VERSION" "$BUILD"
  plutil -replace SUFeedURL -string "$SCRATCH_FEED_URL" "$BUNDLE_PLIST"
  plutil -replace SUPublicEDKey -string "$SCRATCH_PUBLIC_KEY" "$BUNDLE_PLIST"
  plutil -replace SGUpdateTestBundle -bool YES "$BUNDLE_PLIST"
fi

# ---- sign ---------------------------------------------------------------------------------------
echo "→ signing with: $IDENTITY_NAME ($IDENTITY)"
# A secure timestamp is required for notarization and kept for every build that could be handed
# out. Scratch builds skip it (offline, and ad-hoc signatures cannot have one).
TIMESTAMP=(--timestamp)
[[ "$MODE" == scratch ]] && TIMESTAMP=()
ENTITLEMENTS="$ROOT/Resources/Singularity.entitlements"
if [[ "$IDENTITY" == "-" ]]; then
  # As in build-app.sh: an ad-hoc signature has no team, so the hardened runtime would refuse to
  # load the embedded Sparkle.framework. Ad-hoc builds also get Debug.entitlements (library
  # validation off), merged into a temporary copy of the app's own entitlements.
  ENTITLEMENTS="$TEMP_DIR/Singularity.entitlements"
  cp "$ROOT/Resources/Singularity.entitlements" "$ENTITLEMENTS"
  # A relative path (we are in $ROOT): PlistBuddy's command is one string, split at spaces.
  $PB -c "Merge Resources/Debug.entitlements" "$ENTITLEMENTS" >/dev/null
fi
# The self-updater's framework, copied and signed inside-out (before the bundle itself).
"$ROOT/scripts/embed-sparkle.sh" "$APP" "$BIN_DIR" "$IDENTITY" ${TIMESTAMP[@]+"${TIMESTAMP[@]}"}
# Inner executables first, then the bundle.
codesign --force --options runtime ${TIMESTAMP[@]+"${TIMESTAMP[@]}"} --sign "$IDENTITY" "$APP/Contents/MacOS/singularity-mcp"
# Bun's JavaScript engine needs JIT entitlements under the hardened runtime.
codesign --force --options runtime ${TIMESTAMP[@]+"${TIMESTAMP[@]}"} --entitlements "$ROOT/Resources/Bun.entitlements" \
  --sign "$IDENTITY" "$APP/Contents/Helpers/bun"
codesign --force --options runtime ${TIMESTAMP[@]+"${TIMESTAMP[@]}"} --entitlements "$ENTITLEMENTS" \
  --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict --verbose=1 "$APP"
if [[ "$MODE" == release ]]; then
  release_commit_guard "$START_HEAD" || fail "the repository changed during the build."
fi

if [[ "$MODE" == skip-notarize ]]; then
  ditto -c -k --keepParent "$APP" "$ZIP"
  echo "✓ $ZIP (signed, NOT notarized: Gatekeeper will warn on other Macs)"
  SUCCEEDED=1
  exit 0
fi

# ---- notarize -----------------------------------------------------------------------------------
if (( NOTARIZE )); then
  echo "→ notarizing (this usually takes a few minutes)"
  # The upload goes under a temporary name: until Apple has accepted it and the ticket is stapled,
  # nothing called Singularity-<version>.zip exists that could be handed out by mistake.
  rm -f "$ZIP"
  UPLOAD="$DIST/.notarize-upload.zip"
  will_write "$UPLOAD"
  ditto -c -k --keepParent "$APP" "$UPLOAD"
  RESULT="$(xcrun notarytool submit "$UPLOAD" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1)" || { echo "$RESULT"; rm -f "$UPLOAD"; fail "notarytool failed."; }
  echo "$RESULT"
  rm -f "$UPLOAD"
  # notarytool can exit 0 with a verdict of "Invalid"; only "Accepted" may go on.
  grep -q "status: Accepted" <<<"$RESULT" || fail "Apple did not accept the build. See the log with:
       xcrun notarytool log <submission id> --keychain-profile $NOTARY_PROFILE"
  xcrun stapler staple "$APP"
  spctl --assess --type execute --verbose=2 "$APP"
elif (( NOT_NOTARIZED )); then
  echo "→ NOT notarized (no Developer ID certificate or notary profile): this release works on the"
  echo "  developer's Mac; Gatekeeper stops it on other Macs."
fi

# ---- step 5: zip and sign it with the update key ------------------------------------------------
STEP=5
echo "→ step 5: $ZIP"
will_write "$ZIP"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"   # after stapling, so the ticket is inside the download
# sign_update prints the enclosure's attributes: sparkle:edSignature="…" length="…".
# A release signs with the key in the login keychain; a scratch build with its throwaway key file.
SIGN_KEY_ARGS=()
[[ "$MODE" == scratch ]] && SIGN_KEY_ARGS=(--ed-key-file "$SCRATCH_KEY_FILE")
SIGNED="$("$(sparkle_tool sign_update)" ${SIGN_KEY_ARGS[@]+"${SIGN_KEY_ARGS[@]}"} "$ZIP")"
ED_SIGNATURE="$(sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p' <<<"$SIGNED")"
LENGTH="$(sed -n 's/.*length="\([0-9]*\)".*/\1/p' <<<"$SIGNED")"
[[ -n "$ED_SIGNATURE" && -n "$LENGTH" ]] || fail "could not read sign_update's output: $SIGNED"
if [[ "$MODE" == release ]]; then
  rm -rf "$APP"   # the zip is the release; no second stamped copy of the app stays around
  STAMPED_APP=""
fi

# ---- step 6: release notes and appcast.xml ------------------------------------------------------
STEP=6
echo "→ step 6: release notes"
NOTES="$TEMP_DIR/notes.txt"
if [[ -n "$NOTES_FILE" ]]; then
  cp "$NOTES_FILE" "$NOTES"
elif [[ "$MODE" == scratch ]]; then
  echo "Scratch build $VERSION for testing updates." >"$NOTES"
else
  PREVIOUS_TAG="$(git describe --tags --abbrev=0 --match 'v*' 2>/dev/null || true)"
  {
    echo "# Release notes for Singularity $VERSION: one line per point. Lines starting with # are left out."
    echo "# An empty file cancels the release."
    git log --no-show-signature --format='%s' ${PREVIOUS_TAG:+"$PREVIOUS_TAG..HEAD"}
  } >"$NOTES"
  ${EDITOR:-vi} "$NOTES"
  sed -i '' '/^#/d' "$NOTES"
fi
grep -q '[^[:space:]]' "$NOTES" || fail "the release notes are empty; release cancelled."
if (( NOT_NOTARIZED )); then
  { echo "Not notarized: works on the developer's Mac; Gatekeeper stops it elsewhere."; cat "$NOTES"; } >"$NOTES.new"
  mv "$NOTES.new" "$NOTES"
fi

if [[ "$MODE" == scratch ]]; then
  ZIP_URL="${SCRATCH_FEED_URL%/*}/Singularity-$VERSION.zip"   # next to the feed
  APPCAST="$OUT_DIR/appcast.xml"
else
  ZIP_URL="https://github.com/$REPO/releases/download/v$VERSION/Singularity-$VERSION.zip"
  APPCAST="$DIST/appcast.xml"
  will_write "$APPCAST"
fi
"$ROOT/scripts/appcast.sh" --version "$VERSION" --build "$BUILD" --url "$ZIP_URL" --length "$LENGTH" \
  --signature "$ED_SIGNATURE" --min-system "$($PB -c 'Print LSMinimumSystemVersion' "$PLIST")" \
  --notes-file "$NOTES" --out "$APPCAST"

if [[ "$MODE" == scratch ]]; then
  echo "✓ $APP (version $VERSION, scratch)"
  echo "✓ $ZIP"
  echo "✓ $APPCAST"
  SUCCEEDED=1
  exit 0
fi

# The GitHub release's text: the same lines, as a Markdown list.
RELEASE_NOTES="$DIST/release-notes.md"
will_write "$RELEASE_NOTES"
sed -e '/^[[:space:]]*$/d' -e 's/^/- /' "$NOTES" >"$RELEASE_NOTES"

# ---- a last look before the steps that cannot be undone -----------------------------------------
publish_summary() {
  echo
  echo "Ready to publish Singularity $VERSION (build $BUILD):"
  if (( NOTARIZE )); then
    echo "  notarized:  yes"
  else
    echo "  notarized:  NO (Gatekeeper stops it on other Macs)"
  fi
  echo "  signed by:  $IDENTITY_NAME"
  echo "  release notes:"
  sed 's/^/    /' "$RELEASE_NOTES"
}
publish_summary
# The answer is read from the terminal (ask_to_publish, which also asks there). When stdout goes
# somewhere else, such as a log file, the summary is shown in the terminal too.
if [[ "$ASSUME_YES" == 0 && ! -t 1 ]] && { : >/dev/tty; } 2>/dev/null; then
  publish_summary >/dev/tty
fi
ask_to_publish "$ASSUME_YES" || fail "not published; the release is cancelled."

# ---- step 7: commit and push --------------------------------------------------------------------
STEP=7
echo "→ step 7: commit \"Release $VERSION\" and push main"
# Nothing may have changed since step 1 but the bump (scripts/lib/release-guard.sh), and only
# Info.plist goes into the commit. A failure here still restores Info.plist.
release_commit_guard "$START_HEAD" || fail "no release commit made."
git commit -q -m "Release $VERSION" -- Resources/Info.plist
RESTORE_PLIST=0
COMMITTED=1
git push origin main
COMMIT="$(git rev-parse HEAD)"

# ---- step 8: GitHub release ---------------------------------------------------------------------
STEP=8
echo "→ step 8: GitHub release v$VERSION"
gh release create "v$VERSION" --repo "$REPO" --draft --target "$COMMIT" \
  --title "Singularity $VERSION" --notes-file "$RELEASE_NOTES" "$ZIP" "$APPCAST"
gh release edit "v$VERSION" --repo "$REPO" --draft=false --latest

# ---- step 9: done -------------------------------------------------------------------------------
STEP=9
git fetch -q --tags origin
echo "✓ Singularity $VERSION (build $BUILD) is out: https://github.com/$REPO/releases/tag/v$VERSION"
if (( NOT_NOTARIZED )); then
  echo "  Not notarized: works on the developer's Mac; Gatekeeper stops it elsewhere."
fi
SUCCEEDED=1
