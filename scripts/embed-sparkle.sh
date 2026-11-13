#!/usr/bin/env bash
#
# Copies Sparkle.framework (the self-updater) from SwiftPM's build products into an app bundle and
# signs it. Called by build-app.sh and release.sh BEFORE they sign the app bundle itself: the app's
# signature seals Contents/Frameworks, so everything inside has to be signed first.
#
#   scripts/embed-sparkle.sh <app bundle> <bin dir> <sign identity> [--timestamp]
#
#   <bin dir>        output of `swift build --show-bin-path` (SwiftPM puts the framework there)
#   <sign identity>  "-" for ad-hoc, or a certificate fingerprint/name
#   --timestamp      add a secure timestamp (needed for notarization)
#
# Why not `codesign --deep`: it signs nested code in an unspecified order and drops the entitlements
# Sparkle's helpers need. Sparkle's documentation lists this order instead, innermost first:
# the two XPC services, the Autoupdate tool, the Updater app, then the framework.

set -euo pipefail

if [[ $# -lt 3 || $# -gt 4 ]] || [[ $# -eq 4 && "$4" != "--timestamp" ]]; then
  echo "usage: $0 <app bundle> <bin dir> <sign identity> [--timestamp]" >&2
  exit 2
fi
APP="$1"
BIN_DIR="$2"
IDENTITY="$3"
TIMESTAMP=()
[[ "${4:-}" == "--timestamp" ]] && TIMESTAMP=(--timestamp)

SOURCE="$BIN_DIR/Sparkle.framework"
if [[ ! -d "$SOURCE" ]]; then
  echo "error: $SOURCE not found. Build the Singularity product first (it links Sparkle)." >&2
  exit 1
fi

FRAMEWORKS="$APP/Contents/Frameworks"
TARGET="$FRAMEWORKS/Sparkle.framework"
echo "→ embedding Sparkle.framework"
mkdir -p "$FRAMEWORKS"
rm -rf "$TARGET"
# ditto keeps the framework's symlinks (Versions/Current, Sparkle -> Versions/Current/Sparkle, …);
# a copy that follows them would break the framework's layout and its signature.
ditto "$SOURCE" "$TARGET"

sign() {
  codesign --force --options runtime ${TIMESTAMP[@]+"${TIMESTAMP[@]}"} --sign "$IDENTITY" "$@"
}
VERSION_DIR="$TARGET/Versions/B"
sign "$VERSION_DIR/XPCServices/Installer.xpc"
# As in Sparkle's documentation, the downloader keeps whatever entitlements Sparkle shipped it with
# (none in 2.10.1's SwiftPM build, but a later version may add some).
sign --preserve-metadata=entitlements "$VERSION_DIR/XPCServices/Downloader.xpc"
sign "$VERSION_DIR/Autoupdate"
sign "$VERSION_DIR/Updater.app"
sign "$TARGET"
