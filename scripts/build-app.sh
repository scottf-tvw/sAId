#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/common.sh"
configuration=${SAID_CONFIGURATION:-Debug}
case "$configuration" in Debug|Release) ;; *) fail 'SAID_CONFIGURATION must be Debug or Release.' ;; esac
verify_identity
cd "$SAID_ROOT"
xcodegen generate
xcodebuild -project sAId.xcodeproj -scheme sAId -configuration "$configuration" \
    -destination 'platform=macOS' -derivedDataPath "$SAID_BUILD_DIR" \
    "CODE_SIGN_IDENTITY=$SAID_SIGNING_IDENTITY" "DEVELOPMENT_TEAM=$SAID_TEAM_ID" "$@" build
verify_app "$SAID_BUILD_DIR/Build/Products/$configuration/sAId.app"
