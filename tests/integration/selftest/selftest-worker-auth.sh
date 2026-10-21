#!/usr/bin/env bash
set -uo pipefail
echo "== worker API auth verdicts and fixture recovery =="
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../lib.sh"
export INTEGRATION_RUN_SUITE=1
source "$HERE/../lib/run-worker-auth.sh"
rx() { printf 'worker-api response %s\n' "$WIRE_CODE"; }
WIRE_CODE=403
api_state() { printf '%s' "$SAMPLE"; }
SAMPLE='{"workers":[{"name":"rig1","api_ok":false,"adopted":false}],"proxy_workers":1,"proxy_summary":{"accepted":"1,234"}}'
_worker_auth_state rig1 false 403
assert_rc "refused worker feed matches the negative auth verdict" "$?" 0
_worker_auth_state rig1 true 403
assert_rc "a refused feed cannot prove auth recovery" "$?" 1
_worker_auth_state absent false 403
assert_rc "missing worker cannot prove a negative verdict" "$?" 1
_worker_auth_progress 1233
assert_rc "accepted shares must increase" "$?" 0
_worker_auth_progress 1234
assert_rc "an unchanged accepted counter fails" "$?" 1
_worker_auth_progress 1235
assert_rc "a reset accepted counter fails" "$?" 1
SAMPLE='{"workers":[{"name":"rig1","api_ok":true,"adopted":false,"rigforge":{"version":"1.16.0"}}],"proxy_workers":0,"proxy_summary":{"accepted":"1235"}}'
_worker_auth_state rig1 true 403
assert_rc "a recovered enriched feed proves auth success" "$?" 0
_worker_auth_state rig1 false 403
assert_rc "a client accepting a refusal cannot pass the negative arm" "$?" 1
_worker_auth_progress 1234
assert_rc "share growth without a connected miner fails" "$?" 1
SAMPLE='{"workers":[{"name":"rig1","api_ok":true,"adopted":false}]}'
_worker_auth_state rig1 true 403
assert_rc "api_ok alone cannot prove a valid enriched feed" "$?" 1
WIRE_CODE=401
_worker_auth_state rig1 false 403
assert_rc "a missing-credential response cannot prove the wrong-credential arm" "$?" 1
OUT_DIR="$(mktemp -d)"
trap 'rmdir "$OUT_DIR" 2>/dev/null || true' EXIT
push_config() { RESTORED="$1"; }
pithead() { return "$APPLY_RC"; }
wait_status_ok() { return 0; }
_WORKER_AUTH_SAVED_CONFIG='{"workers":{"api_auth":"name"}}'
APPLY_RC=1
_worker_auth_restore
assert_rc "failed restore is visible" "$?" 1
assert_ne "failed restore retains original config for interruption recovery" "$_WORKER_AUTH_SAVED_CONFIG" ""
APPLY_RC=0
_worker_auth_restore
assert_rc "successful restore applies the original config" "$?" 0
assert_eq "restore uses the captured original config" "$RESTORED" '{"workers":{"api_auth":"name"}}'
assert_eq "successful restore disarms repeated config restoration" "$_WORKER_AUTH_SAVED_CONFIG" ""
_WORKER_AUTH_SAVED_CONFIG='{"workers":{"api_auth":"none"}}'
_WORKER_AUTH_CONTAINER=0
_WORKER_AUTH_FOREIGN_TRAP='FOREIGN_RAN=1'
FOREIGN_RAN=0
_worker_auth_abort
assert_rc "interruption recovery succeeds without a safety archive" "$?" 0
assert_eq "interruption restores the original worker auth" "$RESTORED" '{"workers":{"api_auth":"none"}}'
assert_eq "interruption preserves the earlier exit handler" "$FOREIGN_RAN" 1
export IT_MODE=local
BASELINE_CONFIG='{"workers":{"api_auth":"none"},"baseline":true}'
rx() {
    case "$1" in
    'docker container inspect'*) return 1 ;;
    'cat config.json') printf '%s' '{"workers":{"api_auth":"name"},"scenario":true}' ;;
    'docker inspect dashboard'*) printf '%s' test-image ;;
    esac
}
_worker_auth_arm() { return 0; }
APPLY_RC=1
before_failures=$IT_FAIL
run_worker_auth_modes rig1
assert_rc "a failed phase restoration returns failure" "$?" 1
assert_eq "failed phase records its restore failure" "$IT_FAIL" "$((before_failures + 1))"
IT_FAIL=$before_failures
assert_eq "late exit recovery targets the overall baseline instead of a stale scenario" "$_WORKER_AUTH_SAVED_CONFIG" "$BASELINE_CONFIG"
APPLY_RC=0
_worker_auth_abort
assert_rc "late exit recovery can restore the baseline" "$?" 0
assert_eq "late exit cannot overwrite the final baseline with the scenario config" "$RESTORED" "$BASELINE_CONFIG"
trap 'rmdir "$OUT_DIR" 2>/dev/null || true' EXIT
_worker_auth_arm() { _WORKER_AUTH_CONTAINER=1; }
remove_attempts=0
_worker_auth_remove() {
    remove_attempts=$((remove_attempts + 1))
    [ "$remove_attempts" -gt 1 ] || return 1
    _WORKER_AUTH_CONTAINER=0
}
before_failures=$IT_FAIL
run_worker_auth_modes rig1
assert_rc "failed fixture removal returns failure even if config restoration succeeds" "$?" 1
assert_eq "cleanup failure is recorded" "$IT_FAIL" "$((before_failures + 1))"
IT_FAIL=$before_failures
assert_eq "failed cleanup keeps its container ownership" "$_WORKER_AUTH_CONTAINER" 1
assert_contains "failed cleanup retains its exit recovery handler" "$(trap -p EXIT)" _worker_auth_abort
_worker_auth_abort
assert_rc "exit recovery retries failed fixture cleanup" "$?" 0
assert_eq "successful exit cleanup disarms container ownership" "$_WORKER_AUTH_CONTAINER" 0
remove_attempts=0
_WORKER_AUTH_CONTAINER=1
_worker_auth_abort
assert_rc "interrupted cleanup retries one transient removal failure" "$?" 0
assert_eq "interrupted cleanup attempts removal twice" "$remove_attempts" 2
trap - EXIT
rm "$OUT_DIR/worker-auth-restore.apply.log"
echo "selftest-worker-auth: $IT_PASS passed, $IT_FAIL failed"
rmdir "$OUT_DIR"
[ "$IT_FAIL" -eq 0 ]
