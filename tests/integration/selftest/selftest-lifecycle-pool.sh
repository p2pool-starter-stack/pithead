#!/usr/bin/env bash
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/integration/lib.sh
source "$HERE/../lib.sh"
INTEGRATION_RUN_SUITE=1
# shellcheck source=tests/integration/lib/lifecycle-pool.sh
source "$HERE/../lib/lifecycle-pool.sh"

drive_pool_transition() {
    (
        local fixture rc=0 pool
        fixture="$(mktemp -d)"
        trap 'rm -rf "$fixture"' EXIT
        cd "$fixture" || exit 1
        IT_FAIL=0
        BASELINE_CONFIG='{"p2pool":{"pool":"mini"},"monero":{"wallet_address":"fixture-payout"}}'
        printf '%s' "$1" >config.json
        printf '%s\n' "$2" >.env
        CASE="${3:-}"
        if [ "$CASE" = render-fails ]; then render_scenario_config() { return 1; }; fi
        rx() { bash -c "$1"; }
        it_fail() { IT_FAIL=$((IT_FAIL + 1)); }
        wait_for() {
            shift 3
            "$@"
        }
        push_config() {
            [ "$CASE" != push-fails ] || return 1
            printf '%s' "$1" >pending.json
        }
        pithead() {
            [ "$CASE" != apply-fails ] || return 1
            [ "$CASE" != unchanged ] || return 0
            cp pending.json config.json
            printf '%s\n' 'P2POOL_FLAGS=--mini --host fixture' >.env
        }
        wait_status_ok() { [ "$CASE" != unhealthy ]; }
        pool="$(lifecycle_pool_start 2>/dev/null)" || rc=$?
        if [ "$rc" = 0 ]; then
            lifecycle_pool_apply mini >/dev/null 2>&1 || rc=$?
        fi
        printf '%s|%s|%s' "$rc" "$pool" "$IT_FAIL"
        if [ -f pending.json ]; then
            printf '|%s' "$(jq -r '.monero.wallet_address' pending.json)"
        fi
    )
}

assert_eq "a Main scenario switches to Mini while preserving the saved payout" \
    "$(drive_pool_transition '{"p2pool":{"pool":"main"}}' 'P2POOL_FLAGS=--host fixture')" \
    '0|main|0|fixture-payout'
assert_eq "a same-pool apply cannot pass the transition" \
    "$(drive_pool_transition '{"p2pool":{"pool":"main"}}' 'P2POOL_FLAGS=--host fixture' unchanged)" \
    '1|main|1|fixture-payout'
assert_eq "Main with empty clearnet flags is a valid starting sidechain" \
    "$(drive_pool_transition '{"p2pool":{"pool":"main","clearnet":true}}' 'P2POOL_FLAGS=')" \
    '0|main|0|fixture-payout'
for failure in render-fails push-fails apply-fails unhealthy; do
    expected='1|main|1|fixture-payout'
    case "$failure" in render-fails | push-fails) expected='1|main|1' ;; esac
    assert_eq "$failure cannot pass the transition" \
        "$(drive_pool_transition '{"p2pool":{"pool":"main"}}' 'P2POOL_FLAGS=--host fixture' "$failure")" "$expected"
done
for config in '' 'invalid' '[]' '{"p2pool":{"pool":"invalid"}}' '{"p2pool":{"pool":12}}' '{"p2pool":{"pool":false}}'; do
    assert_eq "an unreadable or invalid starting config stops before pushing" \
        "$(drive_pool_transition "$config" 'P2POOL_FLAGS=--host fixture')" '1||0'
done
for flags in '' 'UNRELATED=value' 'P2POOL_FLAGS=--mini'; do
    assert_eq "missing or inconsistent starting flags stop before pushing" \
        "$(drive_pool_transition '{"p2pool":{"pool":"main"}}' "$flags")" '1||0'
done

echo "selftest-lifecycle-pool: $IT_PASS passed, $IT_FAIL failed"
[ "$IT_FAIL" -eq 0 ] || exit 1
