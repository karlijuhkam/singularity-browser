#!/usr/bin/env bash
#
# Writes Sparkle's update feed (appcast.xml) with exactly one entry: the release it is uploaded with.
# Every GitHub release carries its own appcast.xml, and GitHub's "latest" download link always points
# at the newest one, so the feed never has to list older versions.
#
#   scripts/appcast.sh --version 0.2.0 --build 2 \
#     --url https://github.com/<owner>/<repo>/releases/download/v0.2.0/Singularity-0.2.0.zip \
#     --length <zip size in bytes> --signature <edSignature from sign_update> \
#     --min-system 14.0 --notes-file <text file> --out <appcast.xml>
#
# The notes file is plain text: every non-empty line becomes one point of the list Sparkle shows.
# The text is HTML-escaped, so a "<" or "]]>" in a commit subject stays text.
# No sparkle:channel element: every copy sees every release (see the design, "a second track").

set -euo pipefail
source "$(dirname "$0")/lib/version.sh"

usage() {
  echo "usage: $0 --version <N.N.N> --build <number> --url <zip url> --length <bytes>" >&2
  echo "          --signature <edSignature> --min-system <macOS version> --notes-file <file> --out <file>" >&2
  exit 2
}
fail() { echo "error: $*" >&2; exit 1; }

VERSION="" BUILD="" URL="" LENGTH="" SIGNATURE="" MIN_SYSTEM="" NOTES_FILE="" OUT=""
while (( $# )); do
  [[ $# -ge 2 ]] || usage
  case "$1" in
    --version)    VERSION="$2" ;;
    --build)      BUILD="$2" ;;
    --url)        URL="$2" ;;
    --length)     LENGTH="$2" ;;
    --signature)  SIGNATURE="$2" ;;
    --min-system) MIN_SYSTEM="$2" ;;
    --notes-file) NOTES_FILE="$2" ;;
    --out)        OUT="$2" ;;
    *) usage ;;
  esac
  shift 2
done
for value in "$VERSION" "$BUILD" "$URL" "$LENGTH" "$SIGNATURE" "$MIN_SYSTEM" "$NOTES_FILE" "$OUT"; do
  [[ -n "$value" ]] || usage
done
valid_version "$VERSION" || fail "\"$VERSION\" is not a version like 0.2.0."
# A release's build is a whole number; a scratch build (release.sh --scratch) uses its dotted
# version, which Sparkle compares part by part the same way.
[[ "$BUILD" =~ ^[0-9]+(\.[0-9]+)*$ ]] || fail "\"$BUILD\" is not a build number."
[[ "$LENGTH" =~ ^[0-9]+$ ]] || fail "\"$LENGTH\" is not a length in bytes."
[[ "$MIN_SYSTEM" =~ ^[0-9]+(\.[0-9]+)*$ ]] || fail "\"$MIN_SYSTEM\" is not a macOS version."
[[ -r "$NOTES_FILE" ]] || fail "cannot read the notes file $NOTES_FILE."

# &, <, > and " as entities. Used for the notes (HTML inside the CDATA section) and for attribute
# values (XML). After this, the notes cannot contain "]]>", which would end the CDATA section early.
escape() {
  sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g'
}

ITEMS=""
while IFS= read -r line || [[ -n "$line" ]]; do
  [[ "$line" =~ ^[[:space:]]*$ ]] && continue
  ITEMS+="<li>$(printf '%s' "$line" | escape)</li>"
done <"$NOTES_FILE"
[[ -n "$ITEMS" ]] || fail "the notes file $NOTES_FILE has no text."

# RFC 822 date, as RSS wants it; LC_ALL=C keeps the day and month names in English.
PUB_DATE="$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')"

cat >"$OUT" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Singularity</title>
    <item>
      <title>Singularity $VERSION</title>
      <pubDate>$PUB_DATE</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MIN_SYSTEM</sparkle:minimumSystemVersion>
      <description><![CDATA[<ul>$ITEMS</ul>]]></description>
      <enclosure url="$(printf '%s' "$URL" | escape)" length="$LENGTH" type="application/octet-stream" sparkle:edSignature="$(printf '%s' "$SIGNATURE" | escape)"/>
    </item>
  </channel>
</rss>
XML
