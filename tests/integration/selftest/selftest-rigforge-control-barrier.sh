#!/usr/bin/env bash
# Drive the real RigForge control call site through a failed nested read and failed unwind.
# shellcheck disable=SC2034  # globals are read by the eval'd production functions
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/integration/lib.sh
source "$HERE/../lib.sh"
RESTORE_SRC="$(sed -n '/^_restore_rig_control_baseline() {$/,/^}$/p' "$HERE/../lib/run-rig-control.sh")"
CONTROL_SRC="$(sed -n '/^run_rigforge_control() {$/,/^}$/p' "$HERE/../lib/run-rig-control.sh")"
assert_eq "control helpers are extractable" \
    "$(printf '%s\n%s\n' "$RESTORE_SRC" "$CONTROL_SRC" | grep -cE '^(_restore_rig_control_baseline|run_rigforge_control)\(\) \{$')" "2"
eval "$RESTORE_SRC"
eval "$CONTROL_SRC"

TMP="$(mktemp -d)"
trap 'rm -r "$TMP"' EXIT
OUT_DIR="$TMP"
IT_REMOTE_DIR="$TMP"
mkdir -p "$TMP/control/results"
BASELINE_CONFIG='{"dashboard":{"control":{"enabled":false}},"monero":{"mode":"local"},"p2pool":{"pool":"mini"},"workers":{"api_port":8080,"list":[]}}'
CURRENT_CONFIG='{"dashboard":{"control":{"enabled":false}},"monero":{"mode":"remote"},"p2pool":{"pool":"main"},"workers":{"api_port":8080,"list":[]}}'
IT_MODE=local RIG_NAME=rig1 RIG_HOST=rig RIG_CONTROL_PORT=8082 RIGFORGE_BOOTSTRAP_VERSION=""
IT_RIG_TOKEN=$(printf '%032d' 0)
RUN_RIGFORGE=1
api_state() { printf '%s' '{"workers":[{"name":"rig1","rigforge":{"version":"1.17.2"}}]}'; }
env_on_box() { case "$1" in COMPOSE_PROFILES) echo local_node ;; DASHBOARD_AUTH_HASH_B64) echo present ;; CONTROL_DIR) printf '%s' "$TMP/control" ;; esac }
has_compose_profile() { return 0; }
rx() { [ "$1" = 'cat config.json' ] && printf '%s' "$CURRENT_CONFIG"; }
PUSHES=0 READ_PORT="" GLOBAL_PORT=""
push_config() {
    PUSHES=$((PUSHES + 1))
    if [ "$PUSHES" -eq 1 ]; then
        READ_PORT=$(printf '%s' "$1" | jq -r '.workers.list[0].port')
        GLOBAL_PORT=$(printf '%s' "$1" | jq -r '.workers.api_port')
        CONTROL_POOL=$(printf '%s' "$1" | jq -r '.p2pool.pool')
        CONTROL_NODE_MODE=$(printf '%s' "$1" | jq -r '.monero.mode')
    fi
    [ "$PUSHES" -eq 1 ]
}
APPLIES=0
pithead() {
    APPLIES=$((APPLIES + 1))
}
wait_status_ok() { return 0; }
wait_for() { return 0; }
run_rigforge_integration() { it_fail "forced nested read failure" "control"; }
_worker_detail() { : >"$TMP/write-called"; }

echo "== failed read blocks writes and checked unwind is visible =="
run_rigforge_control >/dev/null 2>&1
rc=$?
assert_eq "injected RigForge descriptor selects the enriched API" "$READ_PORT" "8081"
assert_eq "other workers retain their global API port" "$GLOBAL_PORT" "8080"
assert_eq "control config retains the proven scenario pool" "$CONTROL_POOL" "main"
assert_eq "control config retains the proven scenario node mode" "$CONTROL_NODE_MODE" "remote"
assert_eq "failed nested read returns nonzero to main" "$rc" "1"
assert_eq "failed nested read performs no later rig write" "$([ -e "$TMP/write-called" ] && echo yes || echo no)" "no"
assert_eq "a failed baseline write prevents apply from validating stale config" "$APPLIES" "1"
assert_eq "nested read and failed cleanup are both visible" "$IT_FAIL" "2"
early_ok=$([ "$rc" -eq 1 ] && [ ! -e "$TMP/write-called" ] && [ "$APPLIES" -eq 1 ] && [ "$IT_FAIL" -eq 2 ] && echo 1 || echo 0)

echo "== an unreadable current config never reaches push_config =="
IT_FAIL=0 PUSHES=0
rx() { :; }
push_config() { PUSHES=$((PUSHES + 1)); }
run_rigforge_control >/dev/null 2>&1
unreadable_rc=$?
assert_eq "an unreadable current config returns nonzero" "$unreadable_rc" "1"
assert_eq "an unreadable current config is never pushed" "$PUSHES" "0"
unreadable_ok=$([ "$unreadable_rc" -eq 1 ] && [ "$PUSHES" -eq 0 ] && echo 1 || echo 0)

echo "== a late RigForge assertion blocks later destructive phases =="
IT_FAIL=0 RUN_RIGFORGE=0 RIGFORGE_BOOTSTRAP_VERSION=""
BASELINE_CONFIG='{"dashboard":{"control":{"enabled":false}},"workers":{"api_port":8080,"list":[{"name":"rig1","host":"rig"}]}}'
CURRENT_CONFIG="$BASELINE_CONFIG"
rx() {
    if [ "$1" = 'cat config.json' ]; then
        printf '%s' "$CURRENT_CONFIG"
    else
        (cd "$IT_REMOTE_DIR" && bash -c "$1")
    fi
}
_max_temp_round_trip() { :; }
api_state() { printf '%s' '{"workers":[{"name":"rig1","api_ok":true,"rigforge":{"version":"1.17.2","stats":[]}}]}'; }
push_config() { return 0; }
_worker_detail() { printf '%s' '{"editable":true,"control_enabled":true}'; }
WRITABLE_CALLED=0
run_rigforge_writable_keys() {
    WRITABLE_CALLED=$((WRITABLE_CALLED + 1))
    it_fail "forced late RigForge failure" "control"
}
run_rigforge_pools() { :; }
run_rigforge_reverse() { :; }
run_rigforge_rollback() { :; }
run_rigforge_upgrade() { :; }
capture_artifacts() { :; }
run_rigforge_control >/dev/null 2>&1
late_rc=$?
assert_eq "late failure reaches the writable control leg" "$WRITABLE_CALLED" "1"
assert_eq "a late RigForge assertion returns nonzero to main" "$late_rc" "1"
late_ok=$([ "$WRITABLE_CALLED" -eq 1 ] && [ "$late_rc" -eq 1 ] && [ "$IT_FAIL" -eq 1 ] && echo 1 || echo 0)

echo "== a failed current config read rejects even valid JSON stdout =="
IT_FAIL=0 PUSHES=0 WRITABLE_CALLED=0 APPLIES=0
rx() {
    if [ "$1" = 'cat config.json' ]; then
        printf '%s' "$CURRENT_CONFIG"
        return 255
    else
        (cd "$IT_REMOTE_DIR" && bash -c "$1")
    fi
}
push_config() { PUSHES=$((PUSHES + 1)); }
run_rigforge_writable_keys() { WRITABLE_CALLED=$((WRITABLE_CALLED + 1)); }
run_rigforge_control >/dev/null 2>&1
failed_read_rc=$? failed_read_failures=$IT_FAIL
assert_eq "a failed read with valid JSON returns nonzero" "$failed_read_rc" "1"
assert_eq "a failed read with valid JSON records failure" "$failed_read_failures" "1"
assert_eq "a failed read with valid JSON never pushes configuration" "$PUSHES" "0"
assert_eq "a failed read with valid JSON never applies configuration" "$APPLIES" "0"
assert_eq "a failed read with valid JSON never reaches a writable leg" "$WRITABLE_CALLED" "0"
failed_read_ok=$([ "$failed_read_rc" -eq 1 ] && [ "$failed_read_failures" -eq 1 ] && [ "$PUSHES" -eq 0 ] && [ "$APPLIES" -eq 0 ] && [ "$WRITABLE_CALLED" -eq 0 ] && echo 1 || echo 0)

MAIN_SRC="$(sed -n '/^main() {$/,/^}$/p' "$HERE/../run.sh")"
assert_contains "main gates later fault injection on successful RigForge control" "$MAIN_SRC" 'if [ "$rig_control_ok" = 1 ] && [ "$RUN_FAULTS" = "1" ]; then'
assert_contains "main gates later fault injection on a successful lifecycle" "$MAIN_SRC" 'if [ "$lifecycle_ok" = 1 ]; then'
# The forced failures above are product-counter stimuli, not selftest failures.
[ "$early_ok" = 1 ] && [ "$unreadable_ok" = 1 ] && [ "$late_ok" = 1 ] && [ "$failed_read_ok" = 1 ] && [ "$IT_FAIL" -eq 1 ] || exit 1
printf '\nselftest-rigforge-control-barrier: PASS\n'
