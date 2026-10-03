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
lock="$parent/.sAId-install.lock"
mkdir "$lock" 2>/dev/null || fail "Another installation may be active: $lock. If a prior process was interrupted, recover any reported previous.app and remove the stale lock only after confirming no installer is running."
work=""
cleanup() {
    if [ -n "$work" ] && [ -e "$work/previous.app" ]; then
        printf 'sAId: Previous app retained for recovery at %s\n' "$work/previous.app" >&2
    elif [ -n "$work" ]; then
        rm -rf "$work"
    fi
    rmdir "$lock"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
work=$(mktemp -d "$parent/.said-install.XXXXXX")
rename_exclusive="$work/rename-exclusive"
build_rename_helper "$rename_exclusive"
ditto "$SAID_BUILD_DIR/Build/Products/$SAID_CONFIGURATION/sAId.app" "$work/new.app"
verify_app "$work/new.app"
# Recheck after build/staging, including a broken symlink created in the meantime.
[ ! -L "$destination" ] || fail 'Refusing a symlink install destination.'
if [ -e "$destination" ]; then
    [ -d "$destination" ] || fail 'Existing install destination is not a directory.'
    "$rename_exclusive" "$destination" "$work/previous.app"
fi
if ! "$rename_exclusive" "$work/new.app" "$destination"; then
    if [ -e "$work/previous.app" ]; then
        "$rename_exclusive" "$work/previous.app" "$destination" || fail "Install and rollback failed (destination may have changed); recover $work/previous.app manually without overwriting the current destination."
        fail 'Install swap failed; previous app restored.'
    fi
    fail 'Install publication failed; no previous app was moved. Current destination left untouched.'
fi
# Exclusive rename succeeded to the exact path; it never nests inside an appearing directory.
rm -rf "$work/previous.app"
printf 'Installed %s. Launch it explicitly when ready; it has not been opened.\n' "$destination"
