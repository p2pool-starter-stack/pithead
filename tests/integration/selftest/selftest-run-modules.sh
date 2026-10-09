#!/usr/bin/env bash
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$HERE/.."
modules=(run-cli.sh run-matrix.sh run-egress-claim.sh run-onion-targets.sh run-state.sh run-tari-wallet.sh run-lan-guard.sh run-scenario.sh run-source-image.sh run-wizard-defaults.sh run-connection-announcements.sh run-lifecycle.sh run-faults.sh run-pool-sync-fault.sh run-tor-probe-fault.sh run-egress-status.sh run-hardening.sh run-safety.sh run-rigforge.sh run-rig-control.sh run-rig-reverse.sh run-alert-egress.sh run-mergemine-submit.sh run-tari-stranded.sh run-monero-stranded.sh run-mergemine-localnet.sh)

echo "== run.sh modules load completely in their preserved order =="
expected_modules="$(printf 'lib/%s ' "${modules[@]}" | sed 's/ $//')"
actual_modules="$(sed -n 's|^source "$HERE/\(lib/run-[a-z-]*\.sh\)".*|\1|p' "$ROOT/run.sh" | tr '\n' ' ' | sed 's/ $//')"
[ "$actual_modules" = "$expected_modules" ] || {
    echo "integration module order mismatch: $actual_modules" >&2
    exit 1
}

expected_functions='usage parse_args print_list push_config env_on_box running_services _pred_mining_probe_running assert_mining_probe_ready service_state secret_fingerprint preflight record_manifest run_scenario clearnet_flag_effective restore_firewall_after_clearnet assert_host_claims_spent_sync assert_onion_targets assert_running_state assert_egress_dial_pair public_remotes_in_proc_tcp _pred_tari_payouts_found _pred_payout_wallet_ready _pred_monero_wallet_caught_up assert_payout_wallet_ready assert_tari_payout_scan _lan_probe _lan_flush_rules _lan_strip assert_lan_guard_live assert_lan_guard_timer_flush assert_lan_guard_boot_restore assert_lan_guard_boot_failure assert_scenario assert_egress_posture assert_xvb_over_tor assert_metrics_via_caddy assert_doctor_ok assert_share_stats_live assert_telemetry_tables_present assert_current_state box_fstype box_avail_gb box_mode _pred_readiness_status status_verdict_lines assert_release_readiness lifecycle_gate_snippet retain_lifecycle_gate_samples lifecycle_gate_sample source_image_reconcile_snippet run_source_image_reconcile run_cli_wizard_defaults connection_announcements_snippet run_connection_announcements run_lifecycle kept_data_snapshot_snippet kept_chain_files_snippet run_uninstall_round_trip telemetry_rows_diff _pred_status_down _monerod_is _pred_monerod_missing _pred_monerod_unhealthy _pred_monerod_healthy _pred_proxy_stopped _pred_failover_armed _pred_p2pool_running _pred_tor_stopped _pred_tor_healthy fault_node_down fault_unhealthy fault_missing fault_db_readonly fault_firewall_rollback _gf_flows _gf_down fault_firewall_grandfathered_flow fault_tor_down fault_clock_drift fault_disk_enospc _pred_p2pool_peers _pred_dnswatch_listening fault_p2pool_cold_cache_dns _restore_p2pool_peer_lists run_fault_injection p2pool_sidechain_sync_snippet fault_p2pool_sidechain_sync tor_probe_ns_ipt _tor_probe_mining_sample fault_tor_probe_egress _tor_probe_recovered tor_recovery_healthy_probe _await_egress_state fault_firewall_status_alert fault_firewall_boot_restore _set_env_token _spool_write _uuid4 _wait_control_status _onion_reachable_external _remove_control_units run_hardening run_auth_fail_closed safety_backup safety_secret_drift_categories safety_restore_exact safety_rollback_if_failed safety_abort_restore arm_safety_abort_restore safety_cleanup restore_baseline summary run_rigforge_integration assert_subnet_live run_subnet_scenario _worker_apply _max_temp_round_trip _restore_rig_control_baseline run_rigforge_control _pred_rig_present run_rigforge_reverse _rig_control_apply _rig_control_await _pred_feed_maxt _rig_direct_summary _reverse_feed_failure_detail run_rigforge_rollback it_alert_refused _alert_egress_overlay _alert_egress_verdict run_alert_egress_smoke _mm_rows _mm_cleanup run_mergemine_submit tari_ns_ipt tari_strand_count tari_strand_drops tari_strand_remove_all tari_hook_start tari_hook_stop tari_restore_config tari_strand_abort tari_health_field _pred_tari_level _pred_tari_at_least_amber _pred_tari_zero_peers _pred_tari_alerted _pred_tari_recovery_alerted tari_started_at tari_strand_state run_tari_stranded monero_ns_ipt monero_strand_count monero_strand_remove_all monero_hook_start monero_hook_stop monero_restore_config monero_strand_abort monero_health_field _pred_monero_level monero_peer_counts monero_out_peers monero_tor_recovery_out monero_observation _pred_monero_zero_out _pred_monero_has_peers _pred_monerod_docker_health _pred_monero_alerted _pred_monero_recovery_alerted monero_peer_sample _pred_monero_has_peers_sampled monero_peer_wait_diagnostics _monero_http_code assert_monero_p2p_advertisement assert_monero_rpc_boundary monero_started_at monero_strand_state run_monero_stranded _mml_fact _mml_target_row _mml_inspect _mml_ip _mml_cleanup run_mergemine_localnet'
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
# shellcheck source=tests/integration/lib/run-egress-claim.sh
source "$ROOT/lib/run-egress-claim.sh" || exit $?
source "$ROOT/lib/run-onion-targets.sh" || exit $?
# shellcheck source=tests/integration/lib/run-state.sh
source "$ROOT/lib/run-state.sh" || exit $?
# shellcheck source=tests/integration/lib/run-tari-wallet.sh
source "$ROOT/lib/run-tari-wallet.sh" || exit $?
# shellcheck source=tests/integration/lib/run-lan-guard.sh
source "$ROOT/lib/run-lan-guard.sh" || exit $?
# shellcheck source=tests/integration/lib/run-scenario.sh
source "$ROOT/lib/run-scenario.sh" || exit $?
# shellcheck source=tests/integration/lib/run-source-image.sh
source "$ROOT/lib/run-source-image.sh" || exit $?
# shellcheck source=tests/integration/lib/run-wizard-defaults.sh
source "$ROOT/lib/run-wizard-defaults.sh" || exit $?
# shellcheck source=tests/integration/lib/run-connection-announcements.sh
source "$ROOT/lib/run-connection-announcements.sh" || exit $?
# shellcheck source=tests/integration/lib/run-lifecycle.sh
source "$ROOT/lib/run-lifecycle.sh" || exit $?
# shellcheck source=tests/integration/lib/run-faults.sh
source "$ROOT/lib/run-faults.sh" || exit $?
# shellcheck source=tests/integration/lib/run-pool-sync-fault.sh
source "$ROOT/lib/run-pool-sync-fault.sh" || exit $?
# shellcheck source=tests/integration/lib/run-tor-probe-fault.sh
source "$ROOT/lib/run-tor-probe-fault.sh" || exit $?
# shellcheck source=tests/integration/lib/run-egress-status.sh
source "$ROOT/lib/run-egress-status.sh" || exit $?
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
# shellcheck source=tests/integration/lib/run-mergemine-submit.sh
source "$ROOT/lib/run-mergemine-submit.sh" || exit $?
# shellcheck source=tests/integration/lib/run-tari-stranded.sh
source "$ROOT/lib/run-tari-stranded.sh" || exit $?
# shellcheck source=tests/integration/lib/run-monero-stranded.sh
source "$ROOT/lib/run-monero-stranded.sh" || exit $?
# shellcheck source=tests/integration/lib/run-mergemine-localnet.sh
source "$ROOT/lib/run-mergemine-localnet.sh" || exit $?
for fn in $expected_functions assert_xvb_off_no_dwell_churn tari_enable_snapshot run_tari_background_sync; do type "$fn" >/dev/null 2>&1 || exit 1; done

# Execute the wizard harness initialization with the generated CLI: CONFIG_FILE is readonly.
(
    BASELINE_CONFIG='{"monero":{"wallet_address":"fixture"},"tari":{"wallet_address":"fixture"}}'
    IT_PITHEAD="$ROOT/../../pithead"
    quote_arg() { printf '%q' "$1"; }
    rx() {
        local initialization="${1%%wizard_tari_disk_default*}"
        bash -c "$initialization"'test "$CONFIG_FILE" = "$PWD/.itest-wizard-defaults.json"' || return 2
        # Stop before the live wizard/deployment; only its initialization belongs in a selftest.
        return 1
    }
    assert_rc() { [ "$2" = 1 ] || exit 1; }
    if run_cli_wizard_defaults; then exit 1; fi
) || {
    echo "wizard defaults harness could not initialize the generated CLI config override" >&2
    exit 1
}

# The Tor fault must enter the dashboard namespace; host OUTPUT misses same-bridge traffic.
namespace_cmd="$(
    rx() { printf '%s' "$1"; }
    tor_probe_ns_ipt '-I OUTPUT -d 192.0.2.1 -p tcp --dport 9050 -j DROP'
)"
[[ "$namespace_cmd" == *'nsenter -t "$p" -n iptables -I OUTPUT '* ]] || {
    echo "Tor probe fault did not enter the dashboard network namespace" >&2
    exit 1
}

# P2Pool's session counter can be zero while the proxy still accepts real rig shares.
(
    api_state() { printf '%s\n' '{"stratum":{"total_hashes":0},"proxy_summary":{"accepted":"1,201"},"proxy_workers":1}'; }
    jq_get() { printf '%s' "$1" | jq -r "($2)? | values"; }
    EXPECTED_WORKERS=1
    [ "$(_tor_probe_mining_sample)" = 1201 ] || exit 1
    EXPECTED_WORKERS=2
    if _tor_probe_mining_sample >/dev/null; then exit 1; fi
) || {
    echo "Tor probe fault ignored proxy share progress or worker count" >&2
    exit 1
}
declare -f fault_tor_probe_egress | grep -Fq 'wait_for 180 10 "proxy workers online for Tor fault" _tor_probe_mining_sample' || {
    echo "Tor probe fault startup did not use the proxy mining witness" >&2
    exit 1
}
fault_body=$(declare -f fault_tor_probe_egress)
[[ "$fault_body" == *'i + 1 - last_progress'* ]] && [[ "$fault_body" != *'break'* ]] || {
    echo "Tor probe fault must tolerate short share gaps and complete the full fault window" >&2
    exit 1
}

# shellcheck source=tests/integration/lib.sh
source "$ROOT/lib.sh"
OUT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/doctor-modules.XXXXXX")"
trap 'rm -rf "$OUT_DIR"' EXIT

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
