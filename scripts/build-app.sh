#!/usr/bin/env bash
#
# Builds Singularity with SwiftPM and wraps it into build/Singularity.app.
#
#   scripts/build-app.sh                 # debug build, ad-hoc signed
#   CONFIG=release scripts/build-app.sh  # release build
#   SIGN_IDENTITY="Apple Development: …" scripts/build-app.sh
#   APP=/private/tmp/sg-app/Singularity.app scripts/build-app.sh
#       # a second bundle somewhere else, leaving a copy that runs from build/ alone
#
# Why a script: there is no Xcode project. A macOS .app is just a folder with a
# fixed layout (Contents/MacOS/<binary>, Contents/Info.plist, Contents/Resources),
# so we assemble it by hand and sign it.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${CONFIG:-debug}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"   # "-" means ad-hoc signing
APP="${APP:-$ROOT/build/Singularity.app}"

cd "$ROOT"
source "$ROOT/scripts/env.sh"
echo "→ Xcode: ${DEVELOPER_DIR:-$(xcode-select -p)}"

"$ROOT/scripts/fetch-bun.sh"

echo "→ swift build ($CONFIG)"
swift build -c "$CONFIG" --product Singularity
swift build -c "$CONFIG" --product singularity-mcp
swift build -c "$CONFIG" --product singularity-hook
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

echo "→ assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers"
cp "$BIN_DIR/Singularity" "$APP/Contents/MacOS/Singularity"
# The MCP launcher agents start (see README). It lives next to the app's own binary.
cp "$BIN_DIR/singularity-mcp" "$APP/Contents/MacOS/singularity-mcp"
# The command Claude Code runs as a hook (questions and permission requests for the inbox).
cp "$BIN_DIR/singularity-hook" "$APP/Contents/MacOS/singularity-hook"
# The Bun runtime that plugins run on (fetched by scripts/fetch-bun.sh).
cp "$ROOT/Vendor/bun/bun" "$APP/Contents/Helpers/bun"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
if [[ -f "$ROOT/Resources/AppIcon.icns" ]]; then
  cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi
# Images the app loads at runtime (Dock icon per light/dark mode, the orb in empty tabs).
cp "$ROOT"/Resources/*.png "$APP/Contents/Resources/"
# The script every plugin's background program starts through (gives plugins their API).
cp -R "$ROOT/Resources/plugin-host" "$APP/Contents/Resources/"
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

# SwiftPM puts target resources in <Package>_<Target>.bundle next to the binary.
for bundle in "$BIN_DIR"/*.bundle; do
  [[ -e "$bundle" ]] && cp -R "$bundle" "$APP/Contents/Resources/"
done

# The self-updater's framework, copied and signed (it must be signed before the bundle itself).
"$ROOT/scripts/embed-sparkle.sh" "$APP" "$BIN_DIR" "$SIGN_IDENTITY"

echo "→ codesign (identity: $SIGN_IDENTITY)"
# Helper executables inside the bundle must be signed before the bundle itself.
codesign --force --options runtime --sign "$SIGN_IDENTITY" "$APP/Contents/MacOS/singularity-mcp"
codesign --force --options runtime --sign "$SIGN_IDENTITY" "$APP/Contents/MacOS/singularity-hook"
# Bun's JavaScript engine needs JIT entitlements under the hardened runtime.
codesign --force --options runtime --entitlements "$ROOT/Resources/Bun.entitlements" \
  --sign "$SIGN_IDENTITY" "$APP/Contents/Helpers/bun"
ENTITLEMENTS="$ROOT/Resources/Singularity.entitlements"
if [[ "$SIGN_IDENTITY" == "-" ]]; then
  # An ad-hoc signature has no team, so the hardened runtime would refuse to load the embedded
  # Sparkle.framework. Ad-hoc builds therefore also get Debug.entitlements (library validation
  # off), merged into a temporary copy of the app's own entitlements.
  ENTITLEMENTS="$(mktemp -t sg-entitlements)"
  trap 'rm -f "$ENTITLEMENTS"' EXIT
  cp "$ROOT/Resources/Singularity.entitlements" "$ENTITLEMENTS"
  # A relative path (we are in $ROOT): PlistBuddy's command is one string, split at spaces.
  /usr/libexec/PlistBuddy -c "Merge Resources/Debug.entitlements" "$ENTITLEMENTS" >/dev/null
fi
codesign --force --options runtime \
  --entitlements "$ENTITLEMENTS" \
  --sign "$SIGN_IDENTITY" \
  "$APP"

echo "✓ $APP"
