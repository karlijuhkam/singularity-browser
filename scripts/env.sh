# Sourced by the other scripts. Picks an SDK that can build the app.
#
# Why: from the macOS 27 SDK on, SwiftUI's `@State` is a Swift macro whose compiler plugin
# (SwiftUIMacros) ships only with full Xcode, not with the Command Line Tools. Without Xcode we
# therefore build against the newest macOS 26 SDK that CLT includes, where `@State` is still a
# plain property wrapper. With Xcode installed, nothing changes and the default SDK is used.
DEV_DIR="$(xcode-select -p)"
if [[ -z "${SDKROOT:-}" && ! -e "$DEV_DIR/usr/lib/swift/host/plugins/libSwiftUIMacros.dylib" \
      && ! -e "$DEV_DIR/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host/plugins/libSwiftUIMacros.dylib" ]]; then
  SDK_CANDIDATE="$(ls -d "$DEV_DIR"/SDKs/MacOSX26*.sdk 2>/dev/null | sort -V | tail -1)"
  if [[ -n "$SDK_CANDIDATE" ]]; then
    export SDKROOT="$SDK_CANDIDATE"
  fi
fi
