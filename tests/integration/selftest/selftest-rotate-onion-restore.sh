#!/usr/bin/env bash
# The phase's hidden-service backup lies outside config.json/.env, so prove the real EXIT path
# calls it first on both an ordinary failure and a supervisor interruption.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$HERE/.."
# shellcheck source=tests/integration/lib.sh
source "$ROOT/lib.sh"
INTEGRATION_RUN_SUITE=1
# shellcheck source=tests/integration/lib/run-rotate-onion.sh
source "$ROOT/lib/run-rotate-onion.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

trial() {
    local cause="$1"
    local calls="$WORK/$cause"
    local rc
    if ROOT="$ROOT" CALLS="$calls" CAUSE="$cause" bash -c '
        set -uo pipefail
        source "$ROOT/lib.sh"
        INTEGRATION_RUN_SUITE=1
        source "$ROOT/lib/run-rotate-onion.sh"
        source "$ROOT/lib/run-safety.sh"
        rotate_onion_restore() { printf "onion\n" >>"$CALLS"; ROTATE_ONION_RESTORE_ARMED=0; }
        SAFETY_BACKUP=0 RUN_ROTATE_ONION=1 SAFETY_ARCHIVE="" SAFETY_RESTORE_FAILED=0
        _SAFETY_RESTORE_ARMED=0 _SAFETY_FOREIGN_TRAP=""
        safety_backup
        ROTATE_ONION_RESTORE_ARMED=1
        case "$CAUSE" in failure) exit 9 ;; interruption) kill -TERM $$; sleep 1 ;; esac
    ' >/dev/null 2>&1; then
        rc=0
    else
        rc=$?
    fi
    [ "$rc" -ne 0 ] && [ "$(cat "$calls")" = onion ]
}

trial failure && it_pass "a failed onion rotation restores its identity before the safety archive" ||
    it_fail "a failed onion rotation restores its identity before the safety archive"
trial interruption && it_pass "an interrupted onion rotation restores its identity before the safety archive" ||
    it_fail "an interrupted onion rotation restores its identity before the safety archive"

if (
    ROTATE_ONION_RESTORE_ARMED=1 ROTATE_ONION_HS_DIR=/fixture/dashboard
    ROTATE_ONION_BACKUP_DIR=/fixture/preserve ROTATE_ONION_OLD_ADDRESS=old.onion
    ROTATE_ONION_OLD_PUBKEY=pub ROTATE_ONION_OLD_PRIVKEY=priv
    rx() { case "$1" in sudo\ cat*) printf 'old.onion\n' ;; esac }
    pithead() { :; }
    rotate_onion_restore && [ "$ROTATE_ONION_RESTORE_ARMED" = 0 ]
); then
    it_pass "restore verifies the hostname derived from the restored hidden-service keys"
else
    it_fail "restore verifies the hostname derived from the restored hidden-service keys"
fi

if (
    ROTATE_ONION_RESTORE_ARMED=1 ROTATE_ONION_HS_DIR=/fixture/dashboard
    ROTATE_ONION_BACKUP_DIR=/fixture/preserve ROTATE_ONION_OLD_ADDRESS=old.onion
    ROTATE_ONION_OLD_PUBKEY=pub ROTATE_ONION_OLD_PRIVKEY=priv
    rx() { case "$1" in sudo\ cat*) printf 'wrong.onion\n' ;; esac }
    pithead() { :; }
    ! rotate_onion_restore
); then
    it_pass "restore rejects a hidden-service directory for the wrong identity"
else
    it_fail "restore rejects a hidden-service directory for the wrong identity"
fi
