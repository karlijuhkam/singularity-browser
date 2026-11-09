#!/usr/bin/env bash
#
# Builds Singularity with SwiftPM and wraps it into build/Singularity.app.
#
#   scripts/build-app.sh                 # debug build, ad-hoc signed
#   CONFIG=release scripts/build-app.sh  # release build
#   SIGN_IDENTITY="Apple Development: …" scripts/build-app.sh
#
# Why a script: there is no Xcode project. A macOS .app is just a folder with a
# fixed layout (Contents/MacOS/<binary>, Contents/Info.plist, Contents/Resources),
# so we assemble it by hand and sign it.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${CONFIG:-debug}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"   # "-" means ad-hoc signing
APP="$ROOT/build/Singularity.app"

cd "$ROOT"
source "$ROOT/scripts/env.sh"
echo "→ SDK: ${SDKROOT:-default}"

echo "→ swift build ($CONFIG)"
swift build -c "$CONFIG" --product Singularity
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

echo "→ assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Singularity" "$APP/Contents/MacOS/Singularity"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
if [[ -f "$ROOT/Resources/AppIcon.icns" ]]; then
  cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

# SwiftPM puts target resources in <Package>_<Target>.bundle next to the binary.
for bundle in "$BIN_DIR"/*.bundle; do
  [[ -e "$bundle" ]] && cp -R "$bundle" "$APP/Contents/Resources/"
done

echo "→ codesign (identity: $SIGN_IDENTITY)"
codesign --force --options runtime \
  --entitlements "$ROOT/Resources/Singularity.entitlements" \
  --sign "$SIGN_IDENTITY" \
  "$APP"

echo "✓ $APP"
