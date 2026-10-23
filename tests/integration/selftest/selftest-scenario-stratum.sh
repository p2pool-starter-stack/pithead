#!/usr/bin/env bash
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/integration/lib.sh
source "$HERE/../lib.sh"
INTEGRATION_RUN_SUITE=1
# shellcheck source=tests/integration/lib/run-matrix.sh
source "$HERE/../lib/run-matrix.sh"

echo "== Authenticated scenarios hand off and restore borrowed miner credentials (#3491) =="
d="$(mktemp -d)"
trap 'rm -rf "$d"' EXIT

run_fixture() {
    (
        local mode="$1"
        OUT_DIR="$d"
        BASELINE_CONFIG='{"p2pool":{"pool":"main","stratum_password":"auto"},"dashboard":{"tari_required":false}}'
        SKIP_MINING_ASSERTS=0
        [ "$mode" != no-rig ] || SKIP_MINING_ASSERTS=1
        [ "$mode" != open ] || BASELINE_CONFIG='{"p2pool":{"pool":"mini"},"dashboard":{"tari_required":false}}'
        CI_RIG_RECOVERY_HOLD=1
        IT_BORROW_REARM_REQUEST="$d/request" IT_BORROW_REARM_ACK="$d/ack" IT_BORROW_REARM_TOKEN=run-3491
        [ "$mode" != no-controller ] || IT_BORROW_REARM_REQUEST=""
        [ "$mode" != no-hold ] || CI_RIG_RECOVERY_HOLD=0
        active_password=baseline
        resolve_overrides() { RESOLVED=""; }
        render_scenario_config() { printf '%s' "$1"; }
        push_config() { :; }
        pithead() { printf 'apply\n' >>"$d/events"; }
        wait_borrow_rearm() {
            printf '%s\n' "$1" >>"$d/events"
            case "$1" in
            scenario-stratum)
                [ "$mode" != transfer-fails ] || return 1
                active_password=scenario
                ;;
            restore-stratum)
                [ "$mode" != restore-fails ] || return 1
                CI_RIG_RECOVERY_HOLD=1
                IT_BORROW_REARM_REQUEST="$d/request" IT_BORROW_REARM_ACK="$d/ack" IT_BORROW_REARM_TOKEN=run-3491
                [ "$mode" != no-controller ] || IT_BORROW_REARM_REQUEST=""
                [ "$mode" != no-hold ] || CI_RIG_RECOVERY_HOLD=0
                active_password=baseline
                ;;
            esac
        }
        wait_status_ok() { :; }
        wait_monero_synced() { :; }
        wait_miner_running() {
            printf 'miner-wait:%s\n' "$active_password" >>"$d/events"
            [ "$active_password" = scenario ] || [ "$mode" = open ]
        }
        wait_pool_ready() { :; }
        wait_hashes_flowing() { :; }
        assert_scenario() {
            printf 'assert:%s:%s\n' "$SKIP_MINING_ASSERTS" "$active_password" >>"$d/events"
            if [ "$mode" = assertion-fails ]; then
                it_fail 'fixture mining failure' 'intentional'
            elif [ "$SKIP_MINING_ASSERTS" != 1 ] && [ "$mode" != open ] && [ "$active_password" != scenario ]; then
                it_fail 'worker cannot authenticate' 'scenario password was not handed off'
            fi
        }
        restore_firewall_after_clearnet() { :; }
        capture_artifacts() { printf 'capture\n' >>"$d/events"; }
        IT_FAIL=0
        run_scenario fixture '' >/dev/null
        printf 'next:%s\n' "$active_password" >>"$d/events"
        [ "$IT_FAIL" = 0 ]
    )
}

check_fixture() {
    local mode="$1" expected_rc="$2" expected_events="$3" fixture_rc=0
    : >"$d/events"
    run_fixture "$mode" || fixture_rc=$?
    assert_rc "$mode returns the expected result" "$fixture_rc" "$expected_rc"
    assert_eq "$mode preserves credential and assertion order" "$(cat "$d/events")" "$expected_events"
}
check_fixture no-controller 1 'next:baseline'
check_fixture no-hold 1 'next:baseline'
check_fixture authenticated 0 $'apply\nscenario-stratum\nminer-wait:scenario\nassert:0:scenario\nrestore-stratum\nnext:baseline'
check_fixture no-rig 0 $'apply\nassert:1:baseline\nnext:baseline'
check_fixture open 0 $'apply\nminer-wait:baseline\nassert:0:baseline\nnext:baseline'
check_fixture transfer-fails 1 $'apply\nscenario-stratum'
check_fixture restore-fails 1 $'apply\nscenario-stratum\nminer-wait:scenario\nassert:0:scenario\nrestore-stratum'
check_fixture assertion-fails 1 $'apply\nscenario-stratum\nminer-wait:scenario\nassert:0:scenario\nrestore-stratum\ncapture\nnext:baseline'

# shellcheck source=tests/integration/lib/borrow-fixture.sh
source "$HERE/../lib/borrow-fixture.sh"
BENCH_HOST=bench.example
E2E_DIR="$d"
MINER_XMRIG_CONFIG="$d/miner.json"
CI_RIG_RECOVERY_HOLD=1
printf '%s' '{"pools":[{"url":"bench.example:3333","pass":"baseline"},{"url":"original.example:3333","pass":"original"}]}' >"$MINER_XMRIG_CONFIG"
cp "$MINER_XMRIG_CONFIG" "$d/before.json"
printf 'PROXY_STRATUM_PASSWORD=scenario-secret\n' >"$d/.env"
printf 'run-3491 scenario-stratum 1' >"$d/request"
on_bench() { eval "$1"; }
on_miner() { eval "$1"; }
miner_reload() { return 0; }
miner_service_active() { return 0; }
step() { :; }
wait_workers() { return 1; }
wait_for() {
    shift 3
    "$@"
}
handle_borrow_rearm "$d/request" "$d/ack" run-3491
assert_rc 'scenario handoff acknowledges config reload before worker readiness' "$?" 0
assert_eq 'scenario handoff acknowledges only its exact request' "$(cat "$d/ack")" 'run-3491 scenario-stratum 1'
assert_eq 'scenario handoff updates the actual borrowed pool password' "$(jq -r '.pools[0].pass' "$MINER_XMRIG_CONFIG")" scenario-secret
assert_eq 'scenario handoff preserves the original failover credential' "$(jq -r '.pools[1].pass' "$MINER_XMRIG_CONFIG")" original
printf 'run-3491 restore-stratum 2' >"$d/request"
handle_borrow_rearm "$d/request" "$d/ack" run-3491
assert_rc 'scenario restore succeeds through the real controller' "$?" 0
assert_eq 'scenario restore returns every original config byte' "$(cmp -s "$d/before.json" "$MINER_XMRIG_CONFIG" && echo exact)" exact
assert_eq 'scenario restore acknowledges its own sequence' "$(cat "$d/ack")" 'run-3491 restore-stratum 2'

printf '\nselftest-scenario-stratum: %s passed, %s failed\n' "$IT_PASS" "$IT_FAIL"
[ "$IT_FAIL" = 0 ]
