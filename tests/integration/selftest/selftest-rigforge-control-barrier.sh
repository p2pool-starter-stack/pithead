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
BASELINE_CONFIG='{"dashboard":{"control":{"enabled":false}},"workers":{"api_port":8080,"list":[]}}'
IT_MODE=local RIG_NAME=rig1 RIG_HOST=rig RIG_CONTROL_PORT=8082 RIGFORGE_BOOTSTRAP_VERSION=""
IT_RIG_TOKEN=$(printf '%032d' 0)
RUN_RIGFORGE=1
api_state() { printf '%s' '{"workers":[{"name":"rig1","rigforge":{"version":"1.17.2"}}]}'; }
env_on_box() { case "$1" in COMPOSE_PROFILES) echo local_node ;; DASHBOARD_AUTH_HASH_B64) echo present ;; esac }
has_compose_profile() { return 0; }
PUSHES=0 READ_PORT="" GLOBAL_PORT=""
push_config() {
    PUSHES=$((PUSHES + 1))
    if [ "$PUSHES" -eq 1 ]; then
        READ_PORT=$(printf '%s' "$1" | jq -r '.workers.list[0].port')
        GLOBAL_PORT=$(printf '%s' "$1" | jq -r '.workers.api_port')
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
assert_eq "failed nested read returns nonzero to main" "$rc" "1"
assert_eq "failed nested read performs no later rig write" "$([ -e "$TMP/write-called" ] && echo yes || echo no)" "no"
assert_eq "a failed baseline write prevents apply from validating stale config" "$APPLIES" "1"
assert_eq "nested read and failed cleanup are both visible" "$IT_FAIL" "2"

MAIN_SRC="$(sed -n '/^main() {$/,/^}$/p' "$HERE/../run.sh")"
assert_contains "main gates later fault injection on successful RigForge control" "$MAIN_SRC" '[ "$rig_control_ok" = 1 ] && [ "$RUN_FAULTS" = "1" ]'
printf '\nselftest-rigforge-control-barrier: PASS\n'
# Two failures above are the deliberate product-counter stimulus, not selftest failures.
[ "$rc" -eq 1 ] && [ ! -e "$TMP/write-called" ] && [ "$APPLIES" -eq 1 ] && [ "$IT_FAIL" -eq 2 ]
