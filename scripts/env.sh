# Sourced by the other scripts. Selects the Xcode used to build.
#
# Singularity needs full Xcode (the macOS 27 SDK's SwiftUI `@State` macro and SwiftTerm both
# need it). We point builds at it with DEVELOPER_DIR for each command, and deliberately do NOT use
# `sudo xcode-select -s`: that changes the system-wide default, and `git`, `swift` etc. would break
# whenever the drive an Xcode lives on is unplugged.
#
# Where it looks, in order:
#   1. DEVELOPER_DIR, if you set it yourself (nothing else is checked).
#   2. XCODE_APP=/path/to/Xcode.app, if you set it; otherwise the owner's external-drive copy,
#      /Volumes/Zealot/Xcode.app.
#   3. /Applications/Xcode.app, so a normal install works without setting anything.
#   4. The system's selected Xcode, if that is a full Xcode (not the Command Line Tools).
XCODE_APP="${XCODE_APP:-/Volumes/Zealot/Xcode.app}"

if [[ -z "${DEVELOPER_DIR:-}" ]]; then
  if [[ -d "$XCODE_APP/Contents/Developer" ]]; then
    export DEVELOPER_DIR="$XCODE_APP/Contents/Developer"
  elif [[ -d "/Applications/Xcode.app/Contents/Developer" ]]; then
    export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
  elif [[ "$(xcode-select -p)" == *.app/Contents/Developer ]]; then
    : # A full Xcode is already the system default; use it.
  else
    echo "error: full Xcode not found. Set XCODE_APP=/path/to/Xcode.app." >&2
    exit 1
  fi
fi
