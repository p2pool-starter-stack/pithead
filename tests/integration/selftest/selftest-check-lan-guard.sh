#!/usr/bin/env bash
# Exercise the real check/scenario dispatch with box I/O and unrelated verdicts stubbed.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/integration/lib.sh
source "$HERE/../lib.sh"
INTEGRATION_RUN_SUITE=1
# shellcheck source=tests/integration/lib/run-state.sh
source "$HERE/../lib/run-state.sh"
# shellcheck source=tests/integration/lib/run-lan-guard.sh
source "$HERE/../lib/run-lan-guard.sh"
# shellcheck source=tests/integration/lib/run-scenario.sh
source "$HERE/../lib/run-scenario.sh"

TRACE="$(mktemp)"
trap 'rm -f "$TRACE"' EXIT

# These assertions belong to other selftests. Here only the routing of side effects matters.
for fn in it_pass it_fail it_log it_skip_leg assert_eq assert_rc assert_contains assert_num_gt \
    assert_num_ge assert_pool_type assert_mining_state assert_tari_synced_required \
    assert_zmq_publishes assert_mergemine_roundtrip assert_egress_dial_pair \
    assert_egress_posture assert_xvb_over_tor assert_metrics_via_caddy assert_share_stats_live \
    assert_telemetry_tables_present assert_doctor_ok wait_for; do
    eval "$fn() { :; }"
done
clearnet_flag_effective() { echo false; }
rx() { echo 1000; } # Never eval a box command or connect to a host.
env_on_box() { echo true; }
expected_services() { :; }
running_services() { :; }
api_state() { echo '{}'; }
monero_caught_up() { return 0; }
zmq_pub_probe() { :; }
pool_label() { echo Main; }
secret_fingerprint() { echo state-complete >>"$TRACE"; }
pithead() {
    echo "pithead $*" >>"$TRACE"
    [ "$1" != apply ] || echo 'No configuration changes detected'
}
_lan_probe() { echo "probe $*" >>"$TRACE"; }
assert_lan_guard_timer_flush() { echo "timer $*" >>"$TRACE"; }
assert_lan_guard_boot_restore() { echo "boot-restore $*" >>"$TRACE"; }
assert_lan_guard_boot_failure() { echo "boot-failure $*" >>"$TRACE"; }
assert_lan_guard_marker_startup() { echo marker-startup >>"$TRACE"; }
capture_artifacts() { echo artifacts >>"$TRACE"; }

SKIP_MINING_ASSERTS=1 EXPECTED_WORKERS=0 BASELINE_SECRET_FP=fixture IT_FAIL=0

echo "== current-state checks never run the LAN guard scenario battery =="
for config in \
    '{"monero":{"rpc_lan_access":true}}' \
    '{"monero":{"zmq_lan_access":true}}' \
    '{"tari":{"grpc_lan_access":true}}' \
    '{"monero":{"rpc_lan_access":true,"zmq_lan_access":true},"tari":{"grpc_lan_access":true}}'; do
    BASELINE_CONFIG="$config"
    : >"$TRACE"
    assert_current_state
    [ "$(cat "$TRACE")" = "pithead status
state-complete" ] || {
        echo 'current-state check reached a LAN probe, destructive exercise or apply' >&2
        cat "$TRACE" >&2
        exit 1
    }
done

echo "== deploying scenarios retain every LAN probe and recovery exercise =="
: >"$TRACE"
assert_scenario lan "$BASELINE_CONFIG"
[ "$(cat "$TRACE")" = "pithead status
state-complete
probe 198.51.100 18081
probe 10.254.254 18081
probe 198.51.100 18083
probe 10.254.254 18083
probe 198.51.100 18142
probe 10.254.254 18142
timer 18081 18083 18142
boot-restore 18081 18083 18142
boot-failure 18081 18083 18142
marker-startup
pithead apply -y" ] || {
    echo 'deploying scenario lost LAN guard coverage or changed exercise order' >&2
    cat "$TRACE" >&2
    exit 1
}

: >"$TRACE"
assert_scenario no-lan '{}'
[ "$(cat "$TRACE")" = "pithead status
state-complete
marker-startup
pithead apply -y" ] || {
    echo 'scenario without LAN ports ran LAN guard exercises' >&2
    exit 1
}
echo 'selftest-check-lan-guard: PASS'
