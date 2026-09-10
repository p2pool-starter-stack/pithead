#!/usr/bin/env bash
# Pure control for the live node-down fault's pre-arm predicate.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/integration/lib.sh
source "$HERE/../lib.sh"

SRC="$(sed -n '/^_pred_failover_armed() {$/,/^}$/p' "$HERE/../lib/run-lifecycle.sh")"
assert_eq "the failover-arm predicate is extractable" \
    "$(printf '%s\n' "$SRC" | sed -n '1p;$p' | tr '\n' ' ')" \
    "_pred_failover_armed() { } "

arm_result() { # <reachable> <released> <rejected> <proxy-state>
    local state proxy_state="$4"
    state="$(jq -nc --argjson reachable "$1" --argjson released "$2" --argjson rejected "$3" \
        '{monero_sync:{reachable:$reachable},miner_released:$released,workers_rejected:$rejected}')"
    api_state() { printf '%s' "$state"; }
    service_state() { printf '%s' "$proxy_state"; }
    eval "$SRC"
    _pred_failover_armed && echo armed || echo blocked
}

echo "== node-down injection waits for a live dashboard observation =="
assert_eq "a live released stack arms node-down injection" \
    "$(arm_result true true false 'running healthy')" "armed"
assert_eq "an unseen monerod keeps node-down injection blocked" \
    "$(arm_result false true false 'running healthy')" "blocked"
assert_eq "an already-rejected proxy keeps a duplicate fault blocked" \
    "$(arm_result true true true 'exited none')" "blocked"

echo "== node-down call site never injects an unarmed fault =="
FAULT_SRC="$(sed -n '/^fault_node_down() {$/,/^}$/p' "$HERE/../lib/run-faults.sh")"
STOP_LOG="$(mktemp)"
trap 'rm -f "$STOP_LOG"' EXIT
wait_for() { return 1; }
it_fail() { IT_FAIL=$((IT_FAIL + 1)); }
rx() { printf '%s\n' "$*" >>"$STOP_LOG"; }
eval "$FAULT_SRC"
fault_node_down
assert_eq "an unarmed fault records one failure" "$IT_FAIL" "1"
assert_eq "an unarmed fault never calls docker compose stop" "$(grep -c 'stop monerod' "$STOP_LOG")" "0"

echo "== injected RigForge credentials stay out of jq argv =="
CONTROL_SRC="$(sed -n '/^run_rigforge_control() {/,/^}$/p' "$HERE/../lib/run-rig-control.sh")"
assert_eq "the raw rig token is absent from jq arguments" \
    "$(printf '%s' "$CONTROL_SRC" | grep -c -- '--arg tok')" "0"
assert_contains "jq reads the protected process environment" "$CONTROL_SRC" 'token:env.IT_RIG_TOKEN'

HARDENING_SRC="$(sed -n '/^run_hardening() {$/,/^}$/p' "$HERE/../lib/run-hardening.sh")"
assert_eq "full preview configs reach jq on stdin" \
    "$(printf '%s' "$HARDENING_SRC" | grep -c -- '--argjson c')" "0"
