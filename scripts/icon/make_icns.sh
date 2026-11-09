#!/usr/bin/env bash
# Builds Resources/AppIcon.icns from the 1024 px master (AppIcon-dark-1024.png) with iconutil.
# Like the orb on singularity.rroosa.ee: white orb in dark mode, black orb in light mode.
# Re-render the masters first if the orb changes:
#   python3 make_icon.py --variant white --out AppIcon-dark-1024.png    # white orb, dark tile
#   python3 make_icon.py --variant light --out AppIcon-light-1024.png   # black orb, light tile
set -euo pipefail
cd "$(dirname "$0")"
MASTER="AppIcon-dark-1024.png"
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z $size $size "$MASTER" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z $double $double "$MASTER" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o ../../Resources/AppIcon.icns
# The running app switches its Dock icon with light/dark mode (see AppDelegate).
cp AppIcon-dark-1024.png ../../Resources/DockIcon-dark.png
cp AppIcon-light-1024.png ../../Resources/DockIcon-light.png
echo "✓ Resources/AppIcon.icns"
