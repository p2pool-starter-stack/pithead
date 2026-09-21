#!/usr/bin/env bash
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../lib.sh"
source "$HERE/../lib/borrow-fixture.sh"
source "$HERE/../lib/borrow-rearm.sh"

echo "== RigForge writes re-arm the borrowed pool before worker-dependent phases (#1994) =="
MAIN_SRC="$(sed -n '/^main() {$/,/^}$/p' "$HERE/../run.sh")"
control_line="$(printf '%s\n' "$MAIN_SRC" | grep -n 'run_rigforge_control ||' | cut -d: -f1)"
rearm_line="$(printf '%s\n' "$MAIN_SRC" | grep -n 'wait_borrow_rearm' | cut -d: -f1)"
lifecycle_line="$(printf '%s\n' "$MAIN_SRC" | grep -n 'run_lifecycle' | cut -d: -f1)"
subnet_line="$(printf '%s\n' "$MAIN_SRC" | grep -n 'run_subnet_scenario' | tail -n1 | cut -d: -f1)"
assert_eq "verified pool re-arm is after RigForge control and before lifecycle/subnet" \
    "$([ "$control_line" -lt "$rearm_line" ] && [ "$rearm_line" -lt "$lifecycle_line" ] && [ "$rearm_line" -lt "$subnet_line" ] && echo yes)" "yes"

drive_rearm() { # <ack: 0|1> -> request-exists|failure-count
    (
        IT_FAIL=0
        it_fail() { IT_FAIL=$((IT_FAIL + 1)); }
        it_pass() { :; }
        wait_for() {
            shift 3
            "$@"
        }
        d="$(mktemp -d)"
        trap 'rm -rf "$d"' EXIT
        IT_BORROW_REARM_REQUEST="$d/request"
        IT_BORROW_REARM_ACK="$d/ack"
        IT_BORROW_REARM_TOKEN=run-123
        [ "$1" = 0 ] || printf '%s' "$IT_BORROW_REARM_TOKEN" >"$IT_BORROW_REARM_ACK"
        wait_borrow_rearm || true
        printf '%s|%s\n' "$(test -f "$IT_BORROW_REARM_REQUEST" && echo yes)" "$IT_FAIL"
    )
}
assert_eq "acknowledged re-arm writes its request and stays green" "$(drive_rearm 1)" "yes|0"
assert_eq "missing re-arm acknowledgement blocks later phases" "$(drive_rearm 0)" "yes|1"

drive_wrong_ack() {
    (
        IT_FAIL=0
        it_fail() { IT_FAIL=$((IT_FAIL + 1)); }
        it_pass() { :; }
        wait_for() {
            shift 3
            "$@"
        }
        d="$(mktemp -d)"
        trap 'rm -rf "$d"' EXIT
        IT_BORROW_REARM_REQUEST="$d/request" IT_BORROW_REARM_ACK="$d/ack" IT_BORROW_REARM_TOKEN=run-123
        printf stale-run >"$IT_BORROW_REARM_ACK"
        wait_borrow_rearm || true
        printf '%s\n' "$IT_FAIL"
    )
}
assert_eq "a stale or different run's acknowledgement is refused" "$(drive_wrong_ack)" "1"

assert_eq "a credential-rotation request names its action without the secret" "$(
    d="$(mktemp -d)"; trap 'rm -rf "$d"' RETURN
    IT_BORROW_REARM_REQUEST="$d/request" IT_BORROW_REARM_ACK="$d/ack" IT_BORROW_REARM_TOKEN=run-123
    printf run-123 >"$IT_BORROW_REARM_ACK"; it_fail() { :; }; it_pass() { :; }; wait_for() { shift 3; "$@"; }
    wait_borrow_rearm rotate-stratum; cat "$IT_BORROW_REARM_REQUEST"
)" "run-123 rotate-stratum"

HANDLER_SRC="$(sed -n '/^handle_borrow_rearm() {/,/^}$/p' "$HERE/../lib/borrow-fixture.sh")"
controller_rearm_line="$(printf '%s\n' "$HANDLER_SRC" | grep -n 'repoint_miner ||' | cut -d: -f1)"
controller_workers_line="$(printf '%s\n' "$HANDLER_SRC" | grep -n 'wait_workers "$WORKERS"' | cut -d: -f1)"
controller_ack_line="$(printf '%s\n' "$HANDLER_SRC" | grep -n "cat > '\$ack'" | cut -d: -f1)"
assert_eq "controller reloads and observes the worker before acknowledging re-arm" \
    "$([ "$controller_rearm_line" -lt "$controller_workers_line" ] && [ "$controller_workers_line" -le "$controller_ack_line" ] && echo yes)" "yes"

d="$(mktemp -d)"
trap 'rm -rf "$d"' EXIT
printf '%s' '{"pools":[{"url":"original.example:3333","user":"wallet","pass":"rig"}]}' >"$d/config.json"
cp "$d/config.json" "$d/config.json.e2e-orig.anchor"
export BENCH_HOST=bench.example MINER_XMRIG_CONFIG="$d/config.json"
on_miner() { eval "$1"; }
miner_reload() { : >"$d/reloaded"; }
step() { :; }
warn() { :; }
repoint_miner
assert_eq "re-arm makes the test stack the rendered primary pool" \
    "$(jq -r '.pools[0].url' "$d/config.json")" "bench.example:3333"
assert_eq "re-arm tags its injected pool for abort-safe recovery" \
    "$(jq -r '.pools[0]["rig-id"]' "$d/config.json")" "pithead-e2e"
assert_eq "re-arm reloads xmrig" "$(test -f "$d/reloaded" && echo yes)" "yes"
assert_eq "re-arm does not mint or replace the original restore anchor" \
    "$(find "$d" -name '*.e2e-orig.*' | awk 'END {print NR}')" "1"
MINER_ROTATE_CFG_BACKUP="$d/config.json.e2e-rotate"
printf 'new-secret' | rotate_borrowed_stratum_password
assert_eq "credential rotation changes only the borrowed test pool password" \
    "$(jq -r '.pools[0].pass' "$d/config.json")" "new-secret"
restore_borrowed_stratum_password
assert_eq "credential rotation restores the exact borrowed config" \
    "$(jq -r '.pools[0].pass' "$d/config.json")" "rig"
miner_reload() { return 1; }
assert_eq "a failed xmrig reload refuses the re-arm" "$(
    repoint_miner >/dev/null 2>&1
    echo $?
)" "1"

echo "selftest-borrow-rearm: $IT_PASS passed, $IT_FAIL failed"
[ "$IT_FAIL" -eq 0 ] || exit 1
