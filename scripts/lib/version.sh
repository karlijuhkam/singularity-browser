# Version helpers for the release scripts. Sourced, not run:
#   source scripts/lib/version.sh
#
# Singularity's versions are always three whole numbers, "0.2.0" (CFBundleShortVersionString, what
# people see). The build number (CFBundleVersion) is one whole number that goes up by one with every
# release; it is what Sparkle compares.

# valid_version <v>: succeeds when <v> is exactly N.N.N, digits only ("0.2.0"; not "v0.2.0",
# "0.2", "0.2.0-beta", "1.2.3.4").
valid_version() {
  [[ "${1-}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

# version_gt <a> <b>: succeeds when version <a> is higher than <b>, comparing each part as a number,
# so 0.10.0 is higher than 0.9.9. Both must be valid versions.
version_gt() {
  valid_version "${1-}" && valid_version "${2-}" || return 1
  local a b i
  IFS=. read -r -a a <<<"$1"
  IFS=. read -r -a b <<<"$2"
  for i in 0 1 2; do
    # 10#… reads the part as base 10 even with a leading zero ("08" is not octal here).
    if (( 10#${a[i]} > 10#${b[i]} )); then return 0; fi
    if (( 10#${a[i]} < 10#${b[i]} )); then return 1; fi
  done
  return 1   # equal
}

# set_plist_version <Info.plist> <version> <build>: writes the two version fields by editing the
# text in place. PlistBuddy and plutil would rewrite the whole file, dropping its comments and
# reordering its keys; this changes exactly two lines. Fails if either key is not found.
set_plist_version() {
  local plist="$1"
  SG_VERSION="$2" SG_BUILD="$3" perl -0pi -e '
    my $short = s{(<key>CFBundleShortVersionString</key>\s*<string>)[^<]*(</string>)}{$1$ENV{SG_VERSION}$2};
    my $build = s{(<key>CFBundleVersion</key>\s*<string>)[^<]*(</string>)}{$1$ENV{SG_BUILD}$2};
    die "CFBundleShortVersionString or CFBundleVersion not found\n" unless $short == 1 && $build == 1;
  ' "$plist"
}

# claim_web_links <Info.plist>: declares the http and https URL schemes in a *bundle's* Info.plist,
# which is what lets macOS offer the app as the default web browser and send it links.
# Only release.sh calls this, and only for a real release: every bundle built from this repository
# has the same bundle id, so if build/, test or scratch bundles claimed links too, macOS could hand
# a link to a copy that isn't the running one, which exits (the data folder is in use) and the
# link is lost. The checked-in Resources/Info.plist therefore has no CFBundleURLTypes.
claim_web_links() {
  local plist="$1" pb=/usr/libexec/PlistBuddy
  "$pb" -c "Add :CFBundleURLTypes array" \
        -c "Add :CFBundleURLTypes:0 dict" \
        -c "Add :CFBundleURLTypes:0:CFBundleURLName string 'Web site URL'" \
        -c "Add :CFBundleURLTypes:0:CFBundleTypeRole string Viewer" \
        -c "Add :CFBundleURLTypes:0:CFBundleURLSchemes array" \
        -c "Add :CFBundleURLTypes:0:CFBundleURLSchemes:0 string http" \
        -c "Add :CFBundleURLTypes:0:CFBundleURLSchemes:1 string https" \
        "$plist" >/dev/null
}
