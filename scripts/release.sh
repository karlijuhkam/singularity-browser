#!/usr/bin/env bash
#
# Builds a release of Singularity: a universal (Apple Silicon + Intel) app, signed with a
# Developer ID, notarized by Apple and stapled, in dist/.
#
#   scripts/release.sh                   # sign with Developer ID + notarize
#   scripts/release.sh --skip-notarize   # sign only (any identity), for testing the build locally
#
# Environment:
#   TEAM_ID         Apple Developer team that signs Singularity (default: T748B76PPL, Karli Juhkam).
#                   Only that team's certificates are used.
#   SIGN_IDENTITY   explicit codesign identity, overriding the team lookup (default: the team's
#                   "Developer ID Application"; with --skip-notarize, its "Apple Development")
#   NOTARY_PROFILE  notarytool keychain profile (default: singularity-notary). Create it once with:
#                   xcrun notarytool store-credentials singularity-notary --apple-id <you> --team-id <team>
#
# One-time setup for notarization: create a "Developer ID Application" certificate at
# developer.apple.com → Certificates, IDs & Profiles → "+", download it and double-click to install.

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
source "$ROOT/scripts/env.sh"

SKIP_NOTARIZE=0
[[ "${1:-}" == "--skip-notarize" ]] && SKIP_NOTARIZE=1
NOTARY_PROFILE="${NOTARY_PROFILE:-singularity-notary}"
DIST="$ROOT/dist"
APP="$DIST/Singularity.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$ROOT/Resources/Info.plist")"

fail() { echo "error: $*" >&2; exit 1; }

# ---- signing identity ---------------------------------------------------------------------------
# Only certificates of TEAM_ID are considered (the team shown as Singularity's developer); this Mac
# also holds certificates of another company's team, which must never sign Singularity.
# Identities are picked by SHA-1 fingerprint, not by name: a keychain can hold several
# certificates with the same name, and then codesign refuses an ambiguous name.
TEAM_ID="${TEAM_ID:-T748B76PPL}"

# Prints "fingerprint<TAB>team<TAB>name" for every valid code-signing identity.
identities() {
  security find-identity -v -p codesigning | awk '$2 ~ /^[0-9A-F]{40}$/ { print $2 }' | while read -r hash; do
    local pem team name
    pem="$(security find-certificate -a -Z -p | awk -v h="$hash" 'BEGIN { RS = "SHA-1 hash: " } index($0, h) == 1' \
           | sed -n '/BEGIN CERT/,/END CERT/p')"
    team="$(printf '%s\n' "$pem" | openssl x509 -noout -subject -nameopt multiline 2>/dev/null \
            | awk -F' = ' '/organizationalUnitName/ { print $2; exit }')"
    name="$(printf '%s\n' "$pem" | openssl x509 -noout -subject -nameopt multiline 2>/dev/null \
            | awk -F' = ' '/commonName/ { print $2; exit }')"
    printf '%s\t%s\t%s\n' "$hash" "$team" "$name"
  done
}
# First identity of TEAM_ID whose name starts with $1; prints "fingerprint<TAB>name".
identity_in_team() {
  identities | awk -F'\t' -v team="$TEAM_ID" -v prefix="$1" '$2 == team && index($3, prefix) == 1 { print $1 "\t" $3; exit }'
}

if [[ -n "${SIGN_IDENTITY:-}" ]]; then
  IDENTITY="$SIGN_IDENTITY"; IDENTITY_NAME="$SIGN_IDENTITY"
else
  FOUND="$(identity_in_team 'Developer ID Application')"
  if [[ -z "$FOUND" ]] && (( SKIP_NOTARIZE )); then
    FOUND="$(identity_in_team 'Apple Development')"
    [[ -n "$FOUND" ]] && echo "→ no Developer ID certificate in team $TEAM_ID; signing for local testing only"
  fi
  if [[ -z "$FOUND" ]]; then
    if (( SKIP_NOTARIZE )); then
      fail "no signing certificate of team $TEAM_ID in the keychain."
    fi
    fail "no \"Developer ID Application\" certificate of team $TEAM_ID in the keychain. Notarization needs one:
       developer.apple.com → Certificates, IDs & Profiles (team $TEAM_ID) → '+' → Developer ID Application.
       To test the build without it: scripts/release.sh --skip-notarize"
  fi
  IDENTITY="${FOUND%%$'\t'*}"
  IDENTITY_NAME="${FOUND#*$'\t'}"
fi
if (( ! SKIP_NOTARIZE )) && [[ "$IDENTITY_NAME" != Developer\ ID\ Application* ]]; then
  fail "notarization requires a Developer ID Application identity (got: $IDENTITY_NAME)."
fi

# ---- build --------------------------------------------------------------------------------------
"$ROOT/scripts/fetch-bun.sh"

echo "→ building release (universal)"
ARCH_FLAGS=(--arch arm64 --arch x86_64)
if ! swift build -c release "${ARCH_FLAGS[@]}" --product Singularity >/dev/null \
   || ! swift build -c release "${ARCH_FLAGS[@]}" --product singularity-mcp >/dev/null; then
  if (( ! SKIP_NOTARIZE )); then
    fail "the universal (Apple Silicon + Intel) build failed; a release must run on both."
  fi
  echo "warning: universal build failed; building for Apple Silicon only" >&2
  ARCH_FLAGS=(--arch arm64)
  swift build -c release "${ARCH_FLAGS[@]}" --product Singularity
  swift build -c release "${ARCH_FLAGS[@]}" --product singularity-mcp
fi
BIN_DIR="$(swift build -c release "${ARCH_FLAGS[@]}" --show-bin-path)"

echo "→ assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers"
cp "$BIN_DIR/Singularity" "$BIN_DIR/singularity-mcp" "$APP/Contents/MacOS/"
cp "$ROOT/Vendor/bun/bun" "$APP/Contents/Helpers/bun"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
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

# ---- sign ---------------------------------------------------------------------------------------
echo "→ signing with: $IDENTITY_NAME ($IDENTITY)"
# The self-updater's framework, copied and signed inside-out (before the bundle itself).
"$ROOT/scripts/embed-sparkle.sh" "$APP" "$BIN_DIR" "$IDENTITY" --timestamp
# Inner executables first, then the bundle. --timestamp is required for notarization.
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP/Contents/MacOS/singularity-mcp"
# Bun's JavaScript engine needs JIT entitlements under the hardened runtime.
codesign --force --options runtime --timestamp --entitlements "$ROOT/Resources/Bun.entitlements" \
  --sign "$IDENTITY" "$APP/Contents/Helpers/bun"
codesign --force --options runtime --timestamp --entitlements "$ROOT/Resources/Singularity.entitlements" \
  --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict --verbose=1 "$APP"

ZIP="$DIST/Singularity-$VERSION.zip"
if (( SKIP_NOTARIZE )); then
  ditto -c -k --keepParent "$APP" "$ZIP"
  echo "✓ $ZIP (signed, NOT notarized: Gatekeeper will warn on other Macs)"
  exit 0
fi

# ---- notarize -----------------------------------------------------------------------------------
echo "→ notarizing (this usually takes a few minutes)"
# The upload goes under a temporary name: until Apple has accepted it and the ticket is stapled,
# nothing called Singularity-<version>.zip exists that could be handed out by mistake.
rm -f "$ZIP"
UPLOAD="$DIST/.notarize-upload.zip"
ditto -c -k --keepParent "$APP" "$UPLOAD"
RESULT="$(xcrun notarytool submit "$UPLOAD" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1)" || { echo "$RESULT"; rm -f "$UPLOAD"; fail "notarytool failed."; }
echo "$RESULT"
rm -f "$UPLOAD"
# notarytool can exit 0 with a verdict of "Invalid"; only "Accepted" may go on.
grep -q "status: Accepted" <<<"$RESULT" || fail "Apple did not accept the build. See the log with:
       xcrun notarytool log <submission id> --keychain-profile $NOTARY_PROFILE"
xcrun stapler staple "$APP"
ditto -c -k --keepParent "$APP" "$ZIP"   # zipped after stapling, so the ticket is inside the download
spctl --assess --type execute --verbose=2 "$APP"
echo "✓ $ZIP (signed, notarized, stapled)"
