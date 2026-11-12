#!/usr/bin/env bash
#
# Makes a throwaway update key pair for `release.sh <version> --scratch <dir>`, as two files:
#
#   scripts/make-scratch-key.sh <dir>
#     <dir>/key       the private key, in the form Sparkle's sign_update --ed-key-file reads
#                     (base64 of the 32-byte Ed25519 seed)
#     <dir>/key.pub   the public key, for SCRATCH_PUBLIC_KEY (base64 of the 32-byte public key)
#
# It never touches the keychain (Sparkle's own generate_keys always stores its key there).
# Uses Apple's CryptoKit through the Swift interpreter, so it needs nothing beyond the developer tools.
# Then:
#   SCRATCH_KEY_FILE=<dir>/key SCRATCH_PUBLIC_KEY="$(cat <dir>/key.pub)" \
#   SCRATCH_FEED_URL=file:///…/appcast.xml scripts/release.sh 0.1.1 --scratch /private/tmp/…

set -euo pipefail
[[ $# -eq 1 ]] || { echo "usage: $0 <dir>" >&2; exit 2; }
DIR="$1"
[[ ! -e "$DIR/key" ]] || { echo "error: $DIR/key already exists." >&2; exit 1; }
mkdir -p "$DIR"

# Curve25519.Signing.PrivateKey's rawRepresentation is the 32-byte seed; its publicKey's is the
# 32-byte public key. Both printed as base64, one per line.
KEYS="$(swift - <<'SWIFT'
import CryptoKit
let key = Curve25519.Signing.PrivateKey()
print(key.rawRepresentation.base64EncodedString())
print(key.publicKey.rawRepresentation.base64EncodedString())
SWIFT
)"
( umask 077; sed -n 1p <<<"$KEYS" >"$DIR/key" )
sed -n 2p <<<"$KEYS" >"$DIR/key.pub"
echo "✓ $DIR/key (private, throwaway) and $DIR/key.pub ($(cat "$DIR/key.pub"))"
