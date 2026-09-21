#!/usr/bin/env bash
# The phase's hidden-service backup lies outside config.json/.env, so prove the real EXIT path
# calls it first on both an ordinary failure and a supervisor interruption.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$HERE/.."
# shellcheck source=tests/integration/lib.sh
source "$ROOT/lib.sh"
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
        safety_restore_exact() { printf "archive\n" >>"$CALLS"; _SAFETY_RESTORE_ARMED=0; }
        ROTATE_ONION_RESTORE_ARMED=1 SAFETY_ARCHIVE=fixture SAFETY_RESTORE_FAILED=0
        arm_safety_abort_restore
        case "$CAUSE" in failure) exit 9 ;; interruption) kill -TERM $$; sleep 1 ;; esac
    ' >/dev/null 2>&1; then
        rc=0
    else
        rc=$?
    fi
    [ "$rc" -ne 0 ] && [ "$(cat "$calls")" = $'onion\narchive' ]
}

trial failure && it_pass "a failed onion rotation restores its identity before the safety archive" ||
    it_fail "a failed onion rotation restores its identity before the safety archive"
trial interruption && it_pass "an interrupted onion rotation restores its identity before the safety archive" ||
    it_fail "an interrupted onion rotation restores its identity before the safety archive"
