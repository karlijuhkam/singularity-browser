#!/usr/bin/env bash
#
# Builds a release of Singularity: a universal (Apple Silicon + Intel) app, signed with a
# Developer ID, notarized by Apple and stapled, in dist/.
#
#   scripts/release.sh                   # sign with Developer ID + notarize
#   scripts/release.sh --skip-notarize   # sign only (any identity), for testing the build locally
#
# Environment:
#   SIGN_IDENTITY   codesign identity (default: the first "Developer ID Application" in the keychain;
#                   with --skip-notarize, falls back to "Apple Development")
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
# Identities are picked by SHA-1 fingerprint, not by name: a keychain can hold several
# certificates with the same name, and then codesign refuses an ambiguous name.
identity_hash() {   # first identity whose name starts with $1
  security find-identity -v -p codesigning | awk -v prefix="\"$1" 'index($0, prefix) { print $2; exit }'
}
identity_name() {   # display name for a fingerprint
  security find-identity -v -p codesigning | awk -v hash="$1" '$2 == hash { sub(/^[^"]*"/, ""); sub(/"[^"]*$/, ""); print; exit }'
}
IDENTITY="${SIGN_IDENTITY:-$(identity_hash 'Developer ID Application')}"
if [[ -z "$IDENTITY" ]]; then
  if (( SKIP_NOTARIZE )); then
    IDENTITY="$(identity_hash 'Apple Development')"
    [[ -n "$IDENTITY" ]] || fail "no signing identity found in the keychain."
    echo "→ no Developer ID certificate; signing for local testing with: $(identity_name "$IDENTITY")"
  else
    fail "no \"Developer ID Application\" certificate in the keychain. Notarization needs one:
       developer.apple.com → Certificates, IDs & Profiles → '+' → Developer ID Application.
       To test the build without it: scripts/release.sh --skip-notarize"
  fi
fi
IDENTITY_NAME="$(identity_name "$IDENTITY")"
IDENTITY_NAME="${IDENTITY_NAME:-$IDENTITY}"
if (( ! SKIP_NOTARIZE )) && [[ "$IDENTITY_NAME" != Developer\ ID\ Application* ]]; then
  fail "notarization requires a Developer ID Application identity (got: $IDENTITY_NAME)."
fi

# ---- build --------------------------------------------------------------------------------------
echo "→ building release (universal)"
ARCH_FLAGS=(--arch arm64 --arch x86_64)
if ! swift build -c release "${ARCH_FLAGS[@]}" --product Singularity >/dev/null \
   || ! swift build -c release "${ARCH_FLAGS[@]}" --product singularity-mcp >/dev/null; then
  echo "warning: universal build failed; building for Apple Silicon only" >&2
  ARCH_FLAGS=(--arch arm64)
  swift build -c release "${ARCH_FLAGS[@]}" --product Singularity
  swift build -c release "${ARCH_FLAGS[@]}" --product singularity-mcp
fi
BIN_DIR="$(swift build -c release "${ARCH_FLAGS[@]}" --show-bin-path)"

echo "→ assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Singularity" "$BIN_DIR/singularity-mcp" "$APP/Contents/MacOS/"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$ROOT"/Resources/*.png "$APP/Contents/Resources/"
for bundle in "$BIN_DIR"/*.bundle; do
  [[ -e "$bundle" ]] && cp -R "$bundle" "$APP/Contents/Resources/"
done
echo "  architectures: $(lipo -archs "$APP/Contents/MacOS/Singularity")"

# ---- sign ---------------------------------------------------------------------------------------
echo "→ signing with: $IDENTITY_NAME ($IDENTITY)"
# Inner executables first, then the bundle. --timestamp is required for notarization.
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP/Contents/MacOS/singularity-mcp"
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
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"
# Re-zip so the stapled ticket is inside the download.
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
spctl --assess --type execute --verbose=2 "$APP"
echo "✓ $ZIP (signed, notarized, stapled)"
