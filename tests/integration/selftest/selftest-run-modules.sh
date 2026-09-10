#!/usr/bin/env bash
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$HERE/.."
modules=(run-cli.sh run-matrix.sh run-state.sh run-scenario.sh run-lifecycle.sh run-faults.sh run-hardening.sh run-safety.sh run-rigforge.sh run-rig-control.sh run-rig-reverse.sh)

echo "== run.sh modules load completely in their preserved order =="
expected_modules="$(printf 'lib/%s ' "${modules[@]}" | sed 's/ $//')"
actual_modules="$(sed -n 's|^source "$HERE/\(lib/run-[a-z-]*\.sh\)".*|\1|p' "$ROOT/run.sh" | tr '\n' ' ' | sed 's/ $//')"
[ "$actual_modules" = "$expected_modules" ] || {
    echo "integration module order mismatch: $actual_modules" >&2
    exit 1
}

expected_functions='usage parse_args print_list push_config env_on_box running_services service_state secret_fingerprint preflight record_manifest run_scenario assert_running_state assert_scenario assert_egress_posture assert_xvb_over_tor assert_metrics_via_caddy assert_doctor_ok assert_share_stats_live assert_telemetry_tables_present assert_current_state box_fstype box_avail_gb box_mode assert_release_readiness run_lifecycle _pred_status_down _monerod_is _pred_monerod_missing _pred_monerod_unhealthy _pred_monerod_healthy _pred_proxy_stopped _pred_failover_armed _pred_tor_stopped _pred_tor_healthy fault_node_down fault_unhealthy fault_missing fault_db_readonly fault_firewall_rollback fault_tor_down fault_clock_drift fault_disk_enospc run_fault_injection _set_env_token _spool_write _uuid4 _wait_control_status _onion_reachable_external _remove_control_units run_hardening run_auth_fail_closed safety_backup safety_rollback_if_failed safety_cleanup restore_baseline summary run_rigforge_integration assert_subnet_live run_subnet_scenario _worker_apply _restore_rig_control_baseline run_rigforge_control _pred_rig_present run_rigforge_reverse _rig_control_apply _rig_control_await _pred_feed_maxt run_rigforge_rollback'
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
for fn in $expected_functions; do type "$fn" >/dev/null 2>&1 || exit 1; done
echo "selftest-run-modules: PASS"
