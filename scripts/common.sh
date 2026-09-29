#!/bin/bash
# Shared Bash 3.2 packaging helpers. Callers enable errexit, nounset and pipefail.
SAID_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SAID_BUILD_DIR=${SAID_BUILD_DIR:-"$SAID_ROOT/build"}
SAID_TEAM_ID=${SAID_TEAM_ID:-M2TEAF948X}
SAID_SIGNING_IDENTITY=${SAID_SIGNING_IDENTITY:-"Developer ID Application: Scott DL Freeman ($SAID_TEAM_ID)"}

fail() { printf 'sAId: %s\n' "$*" >&2; exit 1; }
verify_identity() {
    case "$SAID_SIGNING_IDENTITY" in "Developer ID Application: "*" ($SAID_TEAM_ID)") ;; *) fail 'Expected a Developer ID Application signing identity for the configured team.' ;; esac
    security find-identity -v -p codesigning | grep -F "\"$SAID_SIGNING_IDENTITY\"" >/dev/null || fail 'Configured Developer ID signing identity is not available or valid.'
}
verify_app() (
    set -euo pipefail
    local app=$1 scratch details key_count resource
    [ -d "$app" ] && [ ! -L "$app" ] || fail 'App must be a real directory.'
    [ -x "$app/Contents/MacOS/sAId" ] || fail 'App executable missing.'
    [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")" = org.tvw.said ] || fail 'Unexpected bundle identity.'
    codesign --verify --deep --strict --verbose=2 -R="identifier \"org.tvw.said\" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"$SAID_TEAM_ID\"" "$app"
    details=$(codesign -dvv "$app" 2>&1)
    printf '%s\n' "$details" | grep -F '(runtime)' >/dev/null || fail 'Hardened runtime missing.'
    lipo "$app/Contents/MacOS/sAId" -verify_arch arm64
    scratch=$(mktemp -d "${TMPDIR:-/tmp}/said-verify.XXXXXX")
    trap 'rm -rf "$scratch"' EXIT
    codesign -d --entitlements - --xml "$app" > "$scratch/entitlements.plist"
    plutil -convert xml1 "$scratch/entitlements.plist"
    [ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.device.audio-input' "$scratch/entitlements.plist")" = true ] || fail 'Audio-input entitlement missing.'
    key_count=$(grep -c '<key>' "$scratch/entitlements.plist")
    [ "$key_count" = 1 ] || fail 'Unexpected additional entitlements.'
    for resource in "$SAID_ROOT"/Resources/*.json "$SAID_ROOT"/Resources/Notices/*; do
        cmp "$resource" "$app/Contents/Resources/${resource##*/}" || fail "Missing or altered resource: ${resource##*/}"
    done
)

# Build in the caller's owned staging directory; no global helper cache or extra runtime dependency.
# Fail closed if the toolchain/filesystem cannot provide macOS RENAME_EXCL semantics.
build_rename_helper() {
    local sdk
    sdk=$(xcrun --sdk macosx --show-sdk-path)
    xcrun clang -isysroot "$sdk" -Wall -Wextra -Werror "$SAID_ROOT/scripts/rename-exclusive.c" -o "$1"
}
