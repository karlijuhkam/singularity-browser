#!/usr/bin/env bash
#
# Fetches the Bun runtime that Singularity bundles (Contents/Helpers/bun) into Vendor/bun/bun,
# as a universal (arm64 + x86_64) binary. The version and both SHA-256 checksums are pinned
# here; a mismatch aborts. Does nothing if that version is already in place.
# Vendor/bun/ is git-ignored (the binary is ~100 MB).
#
# To upgrade: change BUN_VERSION, then recompute both checksums from the release zips
# (and compare them with the release's SHASUMS256.txt).

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

BUN_VERSION="1.4.4"
BUN_SHA256_ARM64="c240d7f0ccb90c263a849fcdb09b7ee62630d921348ed6aafda86b9d577bc510"
BUN_SHA256_X64="50a3491f73abc2fe81673171a85762d3bc2cc1680ccecadd983de99adf77977e"

DEST="$ROOT/Vendor/bun"
BIN="$DEST/bun"

if [[ -x "$BIN" && "$(cat "$DEST/VERSION" 2>/dev/null)" == "$BUN_VERSION" ]]; then
  echo "→ bun $BUN_VERSION already in Vendor/bun"
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fetch() {  # fetch <arch> <expected sha256>
  local arch="$1" want="$2" zip="$WORK/bun-darwin-$1.zip" got
  echo "→ downloading bun $BUN_VERSION ($arch)"
  curl -fsSL -o "$zip" "https://github.com/oven-sh/bun/releases/download/bun-v$BUN_VERSION/bun-darwin-$arch.zip"
  got="$(shasum -a 256 "$zip" | awk '{print $1}')"
  if [[ "$got" != "$want" ]]; then
    echo "error: checksum mismatch for bun-darwin-$arch.zip (expected $want, got $got)" >&2
    exit 1
  fi
  mkdir -p "$WORK/$arch"
  unzip -q "$zip" -d "$WORK/$arch"
}

fetch aarch64 "$BUN_SHA256_ARM64"
fetch x64 "$BUN_SHA256_X64"

mkdir -p "$DEST"
lipo -create "$WORK/aarch64/bun-darwin-aarch64/bun" "$WORK/x64/bun-darwin-x64/bun" -output "$BIN.tmp"
chmod 755 "$BIN.tmp"
mv "$BIN.tmp" "$BIN"
echo "$BUN_VERSION" > "$DEST/VERSION"
echo "✓ $BIN ($("$BIN" --version), $(lipo -archs "$BIN"))"
