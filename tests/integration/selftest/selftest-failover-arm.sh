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

arm_result() { # <monero-sync-state> <proxy-state> [badge text...]
    local sync_state="$1" proxy_state="$2" state
    shift 2
    state="$(jq -nc --arg state "$sync_state" --args \
        '{sync:{monero:{state:$state}},badges:[$ARGS.positional[] | {text: .}]}' "$@")"
    api_state() { printf '%s' "$state"; }
    service_state() { printf '%s' "$proxy_state"; }
    eval "$SRC"
    _pred_failover_armed && echo armed || echo blocked
}

echo "== node-down injection waits for a live dashboard observation =="
assert_eq "a live released stack arms node-down injection" \
    "$(arm_result 'done' 'running healthy')" "armed"
assert_eq "an unseen (still syncing) monerod keeps node-down injection blocked" \
    "$(arm_result 'syncing' 'running healthy')" "blocked"
assert_eq "a held miner keeps node-down injection blocked" \
    "$(arm_result 'done' 'running healthy' 'Miner held (sync)')" "blocked"
assert_eq "an already-rejected proxy keeps a duplicate fault blocked" \
    "$(arm_result 'done' 'exited none' 'Workers rejected')" "blocked"

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
