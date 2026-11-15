#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INTEGRATION_RUN_SUITE=1
# shellcheck source=tests/integration/lib.sh
source "$HERE/../lib.sh"
# shellcheck source=tests/integration/lib/fault-rules.sh
source "$HERE/../lib/fault-rules.sh"
# shellcheck source=tests/integration/lib/run-pool-peer-loss.sh
source "$HERE/../lib/run-pool-peer-loss.sh"

FAIL=0
check() {
    "$@" || {
        FAIL=$((FAIL + 1))
        printf 'FAIL: %s\n' "$*" >&2
    }
}

echo "== the leg tags every rule with the sweep prefix =="
check test "${P2POOL_PEER_LOSS_TAG#"$FAULT_RULE_PREFIX"}" = p2pool-peers
rules=$(p2pool_peer_loss_rules 172.28.0.25)
check test "$(printf '%s\n' "$rules" | wc -l | tr -d ' ')" -eq 4
check test "$(printf '%s\n' "$rules" | grep -c -- "--comment $P2POOL_PEER_LOSS_TAG -j DROP")" -eq 4
check grep -Fq 'OUTPUT -d 172.28.0.25 ' <<<"$rules"
check grep -Fq 'INPUT -p tcp --dport 37888:37890' <<<"$rules"

echo "== a P2Pool that never held peers is a missing-precondition skip, not a pass or a fault =="
(
    injected=0
    env_on_box() { echo /data/p2pool; }
    fault_rules_clear_all() { :; }
    rx() { echo 172.28.0.25; }
    wait_for() { return 1; }
    p2pool_ns_ipt() { injected=1; }
    fault_p2pool_peer_loss
    check test "$injected" -eq 0
    check test "$IT_FAIL" -eq 0
    check test "$IT_PASS" -eq 0
    check test "$IT_SKIPPED_MISSING" -eq 1
    test "$FAIL" -eq 0
)

echo "== a missing data dir is a failure before any work =="
(
    env_on_box() { echo ""; }
    rx() {
        echo "unexpected rx" >&2
        return 1
    }
    fault_p2pool_peer_loss
    check test "$IT_FAIL" -eq 1
    test "$FAIL" -eq 0
)

echo "== a leg that cannot install its rules fails and sweeps =="
(
    cleared=0
    env_on_box() { echo /data/p2pool; }
    fault_rules_clear_all() { cleared=$((cleared + 1)); }
    fault_rules_trap_arm() { :; }
    fault_rules_trap_disarm() { :; }
    rx() { echo 172.28.0.25; }
    wait_for() { return 0; }
    p2pool_ns_ipt() { :; }
    p2pool_peer_loss_count() { echo 0; }
    p2pool_started_at() { echo t0; }
    fault_p2pool_peer_loss
    check test "$IT_FAIL" -eq 1
    check test "$cleared" -eq 2
    test "$FAIL" -eq 0
)

[ "$FAIL" -eq 0 ] && echo "selftest-pool-peer-loss: PASS"
