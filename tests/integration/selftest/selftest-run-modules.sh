#!/usr/bin/env bash
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$HERE/.."
modules=(run-cli.sh run-matrix.sh run-state.sh run-scenario.sh run-lifecycle.sh run-reset-dashboard.sh run-faults.sh run-hardening.sh run-safety.sh run-rigforge.sh run-rig-control.sh run-rig-reverse.sh run-alert-egress.sh)

echo "== run.sh modules load completely in their preserved order =="
expected_modules="$(printf 'lib/%s ' "${modules[@]}" | sed 's/ $//')"
actual_modules="$(sed -n 's|^source "$HERE/\(lib/run-[a-z-]*\.sh\)".*|\1|p' "$ROOT/run.sh" | tr '\n' ' ' | sed 's/ $//')"
[ "$actual_modules" = "$expected_modules" ] || {
    echo "integration module order mismatch: $actual_modules" >&2
    exit 1
}

expected_functions='usage parse_args print_list push_config env_on_box running_services service_state secret_fingerprint preflight record_manifest run_scenario assert_running_state assert_scenario assert_egress_posture assert_xvb_over_tor assert_metrics_via_caddy assert_doctor_ok assert_share_stats_live assert_telemetry_tables_present assert_current_state box_fstype box_avail_gb box_mode assert_release_readiness run_lifecycle _pred_status_down _monerod_is _pred_monerod_missing _pred_monerod_unhealthy _pred_monerod_healthy _pred_proxy_stopped _pred_failover_armed _pred_tor_stopped _pred_tor_healthy _reset_dashboard_services_healthy run_reset_dashboard fault_node_down fault_unhealthy fault_missing fault_db_readonly fault_firewall_rollback fault_tor_down fault_clock_drift fault_disk_enospc run_fault_injection _set_env_token _spool_write _uuid4 _wait_control_status _onion_reachable_external _remove_control_units run_hardening run_auth_fail_closed safety_backup safety_restore_exact safety_rollback_if_failed safety_abort_restore arm_safety_abort_restore reset_dashboard_cleanup safety_cleanup restore_baseline summary run_rigforge_integration assert_subnet_live run_subnet_scenario _worker_apply _restore_rig_control_baseline run_rigforge_control _pred_rig_present run_rigforge_reverse _rig_control_apply _rig_control_await _pred_feed_maxt run_rigforge_rollback it_alert_refused _alert_egress_overlay _alert_egress_verdict run_alert_egress_smoke'
actual_functions="$(for module in "${modules[@]}"; do sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\)() {.*/\1/p' "$ROOT/lib/$module"; done | tr '\n' ' ' | sed 's/ $//')"
[ "$actual_functions" = "$expected_functions" ] || {
    echo "integration function order or completeness mismatch" >&2
    exit 1
}

if bash -c 'source "$1"' _ "$ROOT/lib/run-cli.sh" >/dev/null 2>&1; then
    echo "integration module accepted a direct source without its runner guard" >&2
    exit 1
fi

INTEGRATION_RUN_SUITE=1
# shellcheck source=tests/integration/lib/run-cli.sh
source "$ROOT/lib/run-cli.sh" || exit $?
# shellcheck source=tests/integration/lib/run-matrix.sh
source "$ROOT/lib/run-matrix.sh" || exit $?
# shellcheck source=tests/integration/lib/run-state.sh
source "$ROOT/lib/run-state.sh" || exit $?
# shellcheck source=tests/integration/lib/run-scenario.sh
source "$ROOT/lib/run-scenario.sh" || exit $?
# shellcheck source=tests/integration/lib/run-lifecycle.sh
source "$ROOT/lib/run-lifecycle.sh" || exit $?
# shellcheck source=tests/integration/lib/run-reset-dashboard.sh
source "$ROOT/lib/run-reset-dashboard.sh" || exit $?
# shellcheck source=tests/integration/lib/run-faults.sh
source "$ROOT/lib/run-faults.sh" || exit $?
# shellcheck source=tests/integration/lib/run-hardening.sh
source "$ROOT/lib/run-hardening.sh" || exit $?
# shellcheck source=tests/integration/lib/run-safety.sh
source "$ROOT/lib/run-safety.sh" || exit $?
# shellcheck source=tests/integration/lib/run-rigforge.sh
source "$ROOT/lib/run-rigforge.sh" || exit $?
# shellcheck source=tests/integration/lib/run-rig-control.sh
source "$ROOT/lib/run-rig-control.sh" || exit $?
# shellcheck source=tests/integration/lib/run-rig-reverse.sh
source "$ROOT/lib/run-rig-reverse.sh" || exit $?
# shellcheck source=tests/integration/lib/run-alert-egress.sh
source "$ROOT/lib/run-alert-egress.sh" || exit $?
for fn in $expected_functions; do type "$fn" >/dev/null 2>&1 || exit 1; done

cleanup_command=""
rx() { cleanup_command="$1"; }
quote_arg() { printf "'%s'" "$1"; }
RESET_DASHBOARD_DECOY_DASHBOARD="/tmp/reset-dashboard-decoy-a"
RESET_DASHBOARD_DECOY_P2POOL="/tmp/reset-dashboard-decoy-b"
reset_dashboard_cleanup
[[ "$cleanup_command" == *"rm -rf -- '/tmp/reset-dashboard-decoy-a' '/tmp/reset-dashboard-decoy-b'"* ]] || exit 1
[ -z "$RESET_DASHBOARD_DECOY_DASHBOARD" ] && [ -z "$RESET_DASHBOARD_DECOY_P2POOL" ] || exit 1

reset_service_dashboard="running healthy"
reset_service_p2pool="running healthy"
service_state() {
    case "$1" in
    dashboard) printf '%s' "$reset_service_dashboard" ;;
    p2pool) printf '%s' "$reset_service_p2pool" ;;
    esac
}
_reset_dashboard_services_healthy || exit 1
reset_service_p2pool="running starting"
! _reset_dashboard_services_healthy || exit 1
reset_service_p2pool="running unhealthy"
! _reset_dashboard_services_healthy || exit 1

# reset-dashboard writes a decoy config before it can run. Refuse its direct form before that
# write unless the existing safety EXIT trap will restore the baseline and remove the decoys.
if (
    IT_MODE=local IT_SSH_DEST='' RIG_NAME='' RIGFORGE_BOOTSTRAP_VERSION=''
    RUN_IMAGE_UPGRADE=0 RUN_RESET_DASHBOARD=0 RUN_XVB_ROUTING=0 SAFETY_BACKUP=0 SKIP_MINING_ASSERTS=0
    validate_live_gate_args() { :; }
    it_err() { :; }
    parse_args --local --reset-dashboard
); then
    echo "reset-dashboard accepted without its abort rollback" >&2
    exit 1
elif [ "$?" -ne 2 ]; then
    echo "reset-dashboard missing-backup refusal returned the wrong status" >&2
    exit 1
fi
(
    IT_MODE=local IT_SSH_DEST='' RIG_NAME='' RIGFORGE_BOOTSTRAP_VERSION=''
    RUN_IMAGE_UPGRADE=0 RUN_RESET_DASHBOARD=0 RUN_XVB_ROUTING=0 SAFETY_BACKUP=0 SKIP_MINING_ASSERTS=0
    validate_live_gate_args() { :; }
    it_err() { :; }
    parse_args --local --reset-dashboard --safety-backup
    [ "$RUN_RESET_DASHBOARD" = 1 ] && [ "$SAFETY_BACKUP" = 1 ]
) || {
    echo "reset-dashboard with its abort rollback was rejected" >&2
    exit 1
}

pithead() {
    printf '%s\n' \
        'OK   Tor-only egress firewall is installed — clearnet dials are fail-closed' \
        'OK   workers can connect' \
        'OK   dashboard answers on 127.0.0.1:8000'
}
env_on_box() { [ "$1" = TOR_EGRESS_FIREWALL ] && echo true; }
doctor_checks_failed=0
assert_rc() { [ "$2" = "$3" ] || doctor_checks_failed=$((doctor_checks_failed + 1)); }
assert_contains() { [[ "$2" == *"$3"* ]] || doctor_checks_failed=$((doctor_checks_failed + 1)); }
assert_doctor_ok
[ "$doctor_checks_failed" -eq 0 ] || exit 1

detail="$({
    source "$ROOT/lib.sh"
    env_on_box() { case "$1" in MONERO_CLEARNET_SYNC | TARI_CLEARNET_SYNC) echo false ;; NETWORK_PREFIX) echo 172.28.0 ;; esac }
    rx() { printf '%s\n' '  ✗ tari: 1 PERSISTENT PUBLIC connection(s) — CLEARNET LEAK:' '        198.51.100.42 (3/3 polls)' '[verify-egress] FAIL'; }
    it_fail() { printf '%s' "$2"; }
    it_pass() { :; }
    IT_MODE=local IT_REMOTE_DIR=. assert_egress_posture
})"
[[ "$detail" == *'198.51.100.42 (3/3 polls)'* ]] || {
    echo "leak detail discarded its address and poll count" >&2
    exit 1
}
echo "selftest-run-modules: PASS"
