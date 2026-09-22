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
    ROTATE_ONION_OLD_PUBKEY=pub ROTATE_ONION_OLD_PRIVKEY=priv ROTATE_ONION_OLD_KEY_FP=keys
    rx() { case "$1" in *"sudo cat"*) printf 'old.onion\n' ;; esac }
    rotate_onion_key_fingerprint() { printf 'keys\n'; }
    pithead() { :; }
    wait_status_ok() { :; }
    _onion_reachable_external() { :; }
    rotate_onion_restore && [ "$ROTATE_ONION_RESTORE_ARMED" = 0 ]
); then
    it_pass "restore verifies the keys and hostname derived from the restored hidden-service identity"
else
    it_fail "restore verifies the keys and hostname derived from the restored hidden-service identity"
fi

if (
    ROTATE_ONION_RESTORE_ARMED=1 ROTATE_ONION_HS_DIR=/fixture/dashboard
    ROTATE_ONION_BACKUP_DIR=/fixture/preserve ROTATE_ONION_OLD_ADDRESS=old.onion
    ROTATE_ONION_OLD_PUBKEY=pub ROTATE_ONION_OLD_PRIVKEY=priv ROTATE_ONION_OLD_KEY_FP=keys
    rx() { case "$1" in *"sudo cat"*) printf 'old.onion\n' ;; esac }
    rotate_onion_key_fingerprint() { printf 'wrong-keys\n'; }
    pithead() { :; }
    wait_status_ok() { :; }
    _onion_reachable_external() { :; }
    ! rotate_onion_restore && [ "$ROTATE_ONION_RESTORE_ARMED" = 1 ]
); then
    it_pass "restore rejects mismatched hidden-service key material without logging it"
else
    it_fail "restore rejects mismatched hidden-service key material without logging it"
fi

if (
    ROTATE_ONION_RESTORE_ARMED=1 ROTATE_ONION_HS_DIR=/fixture/dashboard
    ROTATE_ONION_BACKUP_DIR=/fixture/preserve ROTATE_ONION_OLD_ADDRESS=old.onion
    ROTATE_ONION_OLD_PUBKEY=pub ROTATE_ONION_OLD_PRIVKEY=priv ROTATE_ONION_OLD_KEY_FP=keys
    render_calls=0
    rx() { case "$1" in *"sudo cat"*) printf 'old.onion\n' ;; esac }
    rotate_onion_key_fingerprint() { printf 'keys\n'; }
    pithead() {
        render_calls=$((render_calls + 1))
        [ "$render_calls" -gt 1 ]
    }
    wait_status_ok() { :; }
    _onion_reachable_external() { :; }
    ! rotate_onion_restore && [ "$ROTATE_ONION_RESTORE_ARMED" = 1 ] &&
        rotate_onion_restore && [ "$ROTATE_ONION_RESTORE_ARMED" = 0 ]
); then
    it_pass "a post-swap render failure stays armed and succeeds on EXIT retry"
else
    it_fail "a post-swap render failure stays armed and succeeds on EXIT retry"
fi

if (
    rx() { printf '/srv/fixture-tor\n'; }
    [ "$(rotate_onion_data_dir /srv/fixture-tor)" = /srv/fixture-tor ] &&
        ! rotate_onion_data_dir relative/path && ! rotate_onion_data_dir / &&
        ! rotate_onion_data_dir /srv/fixture-tor/../fixture-tor
); then
    it_pass "TOR_DATA_DIR must be an existing canonical absolute non-root directory"
else
    it_fail "TOR_DATA_DIR must be an existing canonical absolute non-root directory"
fi
