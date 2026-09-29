#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/common.sh"
[ "$#" = 1 ] || fail 'Usage: scripts/release.sh VERSION (for example 1.0.0)'
version=$1
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail 'Version must be three dot-separated integers.'
dist=${SAID_DIST_DIR:-"$SAID_ROOT/dist"}
profile=${SAID_NOTARY_PROFILE:-said-notary}
mkdir -p "$dist"
# Never overwrite a previously notarized artifact or leave a misleading final zip on failure.
final="$dist/sAId-$version.zip"
[ ! -e "$final" ] && [ ! -L "$final" ] || fail "Release already exists: $final"
work=$(mktemp -d "$dist/.said-release.XXXXXX")
trap 'rm -rf "$work"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
rename_exclusive="$work/rename-exclusive"
build_rename_helper "$rename_exclusive"
export SAID_CONFIGURATION=Release
"$SAID_ROOT/scripts/build-app.sh" "MARKETING_VERSION=$version" "CURRENT_PROJECT_VERSION=$version"
ditto "$SAID_BUILD_DIR/Build/Products/Release/sAId.app" "$work/sAId.app"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$work/sAId.app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $version" "$work/sAId.app/Contents/Info.plist"
verify_identity
codesign --force --sign "$SAID_SIGNING_IDENTITY" --options runtime --timestamp --entitlements "$SAID_ROOT/sAId.entitlements" "$work/sAId.app"
verify_app "$work/sAId.app"
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$work/sAId.app/Contents/Info.plist")" = "$version" ] || fail 'Bundle version did not update.'
ditto -c -k --sequesterRsrc --keepParent "$work/sAId.app" "$work/notary-submission.zip"
if ! xcrun notarytool submit "$work/notary-submission.zip" --keychain-profile "$profile" --wait --output-format json > "$work/notary.json"; then
    printf 'sAId: Notarization failed. If the profile is unavailable, provision it interactively in your terminal:\n  xcrun notarytool store-credentials %s --team-id %s\nNever put credentials in chat or the repository. No final release zip was created.\n' "$profile" "$SAID_TEAM_ID" >&2
    exit 1
fi
[ "$(plutil -extract status raw -o - "$work/notary.json")" = Accepted ] || fail 'Notarization was not Accepted. No final release zip was created.'
xcrun stapler staple "$work/sAId.app"
xcrun stapler validate "$work/sAId.app"
verify_app "$work/sAId.app"
ditto -c -k --sequesterRsrc --keepParent "$work/sAId.app" "$work/final.zip"
[ ! -e "$final" ] && [ ! -L "$final" ] || fail "Release appeared during build: $final"
"$rename_exclusive" "$work/final.zip" "$final" || fail "Release publication failed; any existing archive was preserved: $final"
printf 'Notarized and stapled release: %s\nNo release has been published.\n' "$final"
