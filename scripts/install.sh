#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/common.sh"
export SAID_CONFIGURATION=${SAID_CONFIGURATION:-Release}
# Build and verify before even creating a staging directory at the destination.
"$SAID_ROOT/scripts/build-app.sh"
destination=${SAID_INSTALL_DEST:-/Applications/sAId.app}
case "$destination" in /*/sAId.app) ;; *) fail 'SAID_INSTALL_DEST must be an absolute path ending in /sAId.app.' ;; esac
parent=${destination%/*}
[ -d "$parent" ] && [ -w "$parent" ] || fail "Destination directory must exist and be writable: $parent (no sudo is invoked)."
work=$(mktemp -d "$parent/.said-install.XXXXXX")
cleanup() {
    if [ -e "$work/previous.app" ]; then
        printf 'sAId: Previous app retained for recovery at %s\n' "$work/previous.app" >&2
    else
        rm -rf "$work"
    fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
ditto "$SAID_BUILD_DIR/Build/Products/$SAID_CONFIGURATION/sAId.app" "$work/new.app"
verify_app "$work/new.app"
# Recheck after build/staging, including a broken symlink created in the meantime.
[ ! -L "$destination" ] || fail 'Refusing a symlink install destination.'
if [ -e "$destination" ]; then
    [ -d "$destination" ] || fail 'Existing install destination is not a directory.'
    mv "$destination" "$work/previous.app"
fi
if ! mv "$work/new.app" "$destination"; then
    if [ -e "$work/previous.app" ]; then
        mv "$work/previous.app" "$destination" || fail "Install and rollback failed; recover $work/previous.app manually."
    fi
    fail 'Install swap failed; previous app restored.'
fi
# The verified app was renamed on the same filesystem; no post-swap copying occurs.
rm -rf "$work/previous.app"
printf 'Installed %s. Launch it explicitly when ready; it has not been opened.\n' "$destination"
