# Sourced by the other scripts. Selects the Xcode used to build.
#
# Singularity needs full Xcode (the macOS 27 SDK's SwiftUI `@State` macro and SwiftTerm both
# need it). Xcode lives on the external drive "Zealot", so we point builds at it with
# DEVELOPER_DIR for each command. We deliberately do NOT use `sudo xcode-select -s`: that changes
# the system-wide default, and `git`, `swift` etc. would break whenever the drive is unplugged.
#
# Override the location with XCODE_APP=/path/to/Xcode.app, or set DEVELOPER_DIR yourself.
XCODE_APP="${XCODE_APP:-/Volumes/Zealot/Xcode.app}"

if [[ -z "${DEVELOPER_DIR:-}" ]]; then
  if [[ -d "$XCODE_APP/Contents/Developer" ]]; then
    export DEVELOPER_DIR="$XCODE_APP/Contents/Developer"
  elif [[ "$(xcode-select -p)" == *.app/Contents/Developer ]]; then
    : # A full Xcode is already the system default; use it.
  else
    echo "error: Xcode not found at $XCODE_APP. Is the Zealot drive mounted?" >&2
    echo "       Set XCODE_APP=/path/to/Xcode.app to use another copy." >&2
    exit 1
  fi
fi
