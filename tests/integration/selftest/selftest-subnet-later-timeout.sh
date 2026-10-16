#!/usr/bin/env bash
# shellcheck disable=SC2034 # fixture globals are consumed by sourced battery functions
# Later sync/hash timeouts must capture before the next wait or assertion.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../lib.sh"
INTEGRATION_RUN_SUITE=1
source "$HERE/../lib/run-state.sh"
td=$(mktemp -d)
trap 'rm -rf "$td"' EXIT
echo "== later subnet timeouts through the real running-state battery =="
for stage in panel rpc hashes; do
    (
        OUT_DIR="$td/$stage" SUBNET_TIMEOUT_ACTIVE=1 SUBNET_TIMEOUT_CAPTURED=0
        SKIP_MINING_ASSERTS=0 EXPECTED_WORKERS=1
        mkdir -p "$OUT_DIR"
        now_s() {
            local tick=0
            [ ! -f "$OUT_DIR/clock" ] || read -r tick <"$OUT_DIR/clock"
            echo "$((tick + 2000))" >"$OUT_DIR/clock"
            echo "$tick"
        }
        sleep() {
            echo unexpected-sleep >>"$OUT_DIR/order"
            return 1
        }
        rx() {
            case "$1" in
            *subnet-diagnostics.py*)
                echo capture >>"$OUT_DIR/order"
                printf '{"fixture":true}\n'
                return 124
                ;;
            *"HiddenServiceDir /var/lib/tor/tari/"*) echo 0 ;;
            *) echo 1 ;;
            esac
        }
        jq_get() {
            case "$2" in
            .monero.mode) if [ "$1" = '{}' ]; then echo Full; else echo local; fi ;;
            .tari.mode) echo off ;;
            .sync.monero.state) echo "done" ;;
            *) echo false ;;
            esac
        }
        clearnet_flag_effective() { echo false; }
        running_services() { echo p2pool; }
        expected_services() { echo p2pool; }
        assert_onion_targets() { :; }
        pithead() { :; }
        api_state() { echo '{}'; }
        _pred_monero_panel_done() {
            [ "$stage" != panel ]
        }
        monero_caught_up() {
            if [ "$stage" = panel ]; then
                [ -s "$OUT_DIR/subnet-first-timeout/summary.jsonl" ] || exit 9
            fi
            [ "$stage" != rpc ]
        }
        _pred_stratum_hashes() { [ "$stage" != hashes ]; }
        assert_miner_connection_live() { :; }
        zmq_pub_probe() { :; }
        assert_zmq_publishes() { :; }
        assert_pool_type() { :; }
        it_fail() {
            echo failure >>"$OUT_DIR/order"
            [ -s "$OUT_DIR/subnet-first-timeout/summary.jsonl" ] || exit 9
        }
        assert_mining_state() {
            echo assertion >>"$OUT_DIR/order"
            [ "$SUBNET_TIMEOUT_CAPTURED" = 1 ] || exit 9
            [ -s "$OUT_DIR/subnet-first-timeout/summary.jsonl" ] || exit 9
            [ "$(grep -c '^capture$' "$OUT_DIR/order")" = 1 ] || exit 9
            grep -Fxq collector_exit=124 "$OUT_DIR/subnet-first-timeout/collector-exit.txt" || exit 9
            exit 0
        }
        assert_running_state subnet '{"fixture":true}' >/dev/null
        exit 9 # Must reach the real mining assertion.
    )
    assert_rc "earlier release succeeds; later $stage timeout captures before assertion" "$?" 0
done
(
    OUT_DIR="$td/waiter" SUBNET_TIMEOUT_ACTIVE=1 SUBNET_TIMEOUT_CAPTURED=0
    mkdir -p "$OUT_DIR"
    now_s() { echo 0; }
    sleep() { echo "$1" >>"$OUT_DIR/cadence"; }
    predicate() { [ -f "$OUT_DIR/cadence" ]; }
    wait_for 150 5 fixture predicate || exit 9
    [ ! -e "$OUT_DIR/subnet-first-timeout" ] || exit 9
    [ "$(cat "$OUT_DIR/cadence")" = 5 ] || exit 9
    unset SUBNET_TIMEOUT_ACTIVE
    now_s() { echo 0; }
    wait_for 0 10 fixture false && exit 9
    [ ! -e "$OUT_DIR/subnet-first-timeout" ]
) >/dev/null
assert_rc 'successful polling and unrelated timeouts retain cadence and verdict' "$?" 0
(
    OUT_DIR="$td/repeated" SUBNET_TIMEOUT_ACTIVE=1 SUBNET_TIMEOUT_CAPTURED=0
    mkdir -p "$OUT_DIR"
    now_s() { echo 0; }
    rx() {
        echo capture >>"$OUT_DIR/order"
        return 124
    }
    wait_for 0 5 'private predicate description' false && exit 9
    wait_for 0 10 'another private description' false && exit 9
    [ "$(grep -c '^capture$' "$OUT_DIR/order")" = 1 ] || exit 9
    grep -q '^stage=readiness utc=' "$OUT_DIR/subnet-first-timeout/trigger.txt" || exit 9
    ! grep -q private "$OUT_DIR/subnet-first-timeout/trigger.txt"
) >/dev/null
assert_rc 'repeated timeouts keep failure verdicts and one fixed-stage snapshot' "$?" 0
echo "selftest-subnet-later-timeout: $IT_PASS passed, $IT_FAIL failed"
[ "$IT_FAIL" -eq 0 ]
