#!/usr/bin/env bash
# Sparse configs retain the renderer's mini default in readiness and lifecycle switching.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/integration/lib.sh
source "$HERE/../lib.sh"
INTEGRATION_RUN_SUITE=1
# shellcheck source=tests/integration/lib/run-matrix.sh
source "$HERE/../lib/run-matrix.sh"
# shellcheck source=tests/integration/lib/run-lifecycle.sh
source "$HERE/../lib/run-lifecycle.sh"

echo "== sparse and explicit pool choices in readiness and lifecycle =="

# Execute the shipped phase functions with only their box I/O and unrelated assertions stubbed.
# Real JSON rendering, jq_get and pool_label preserve the omitted-key/explicit-choice contract.
drive_pool() { # <scenario|lifecycle> <config> [overrides]
    (
        # shellcheck disable=SC2034 # globals consumed by sourced phase functions
        BASELINE_CONFIG="$2" SKIP_MINING_ASSERTS=1 IT_FAIL=0
        OUT_DIR="$(mktemp -d)"
        trap 'rm -rf "$OUT_DIR"' EXIT
        TRACE="$OUT_DIR/trace"
        : >"$TRACE"
        it_log() { :; }
        it_step() { :; }
        it_pass() { :; }
        it_skip_leg() { :; }
        # Treat any unexpected phase failure as a failed driver, not a hidden diagnostic.
        it_fail() { printf 'failure:%s\n' "$1" >>"$TRACE"; }
        pithead() { :; }
        wait_status_ok() { :; }
        wait_monero_synced() { :; }
        secret_fingerprint() { printf 'test-fingerprint'; }
        upgrade_secret_fingerprints() { printf 'test-fingerprint'; }
        env_on_box() { :; }
        has_compose_profile() { return 1; }
        run_source_image_reconcile() { :; }
        run_connection_announcements() { :; } # Box-output proof is covered by its own selftest.
        tor_recovery_healthy_probe() { :; }
        run_uninstall_round_trip() { :; }
        assert_scenario() { :; }
        restore_firewall_after_clearnet() { :; }
        assert_rc() { :; }
        assert_eq() { :; }
        wait_for() { :; }
        api_state() { printf '{"pool":{"type":"Main"}}'; }
        rx() {
            case "$1" in
            'test -f dashboard/Dockerfile') return 1 ;;
            ls*) printf 'backups/test.tar.gz' ;;
            esac
        }
        push_config() {
            printf 'push:%s\n' "$(jq_get "$1" '.p2pool.pool')" >>"$TRACE"
        }
        wait_pool_ready() { printf 'ready:%s:%s\n' "$1" "$2" >>"$TRACE"; }
        assert_pool_switched() { printf 'switch:%s:%s\n' "$1" "$2" >>"$TRACE"; }
        case "$1" in
        scenario) run_scenario sparse-pool "${3:-}" >/dev/null 2>>"$TRACE" ;;
        lifecycle) run_lifecycle >/dev/null 2>>"$TRACE" ;;
        *) exit 2 ;;
        esac
        cat "$TRACE"
    )
}

for case_name in omitted empty-section main mini nano; do
    case "$case_name" in
    omitted) config='{}' pool='' expected=Mini alternate=main ;;
    empty-section) config='{"p2pool":{}}' pool='' expected=Mini alternate=main ;;
    main) config='{"p2pool":{"pool":"main"}}' pool=main expected=Main alternate=mini ;;
    mini) config='{"p2pool":{"pool":"mini"}}' pool=mini expected=Mini alternate=main ;;
    nano) config='{"p2pool":{"pool":"nano"}}' pool=nano expected=Nano alternate=mini ;;
    esac
    assert_eq "$case_name waits for its effective pool" \
        "$(drive_pool scenario "$config")" "$(printf 'push:%s\nready:180:%s' "$pool" "$expected")"
    assert_eq "$case_name lifecycle applies and checks the alternate pool" \
        "$(drive_pool lifecycle "$config")" \
        "$(printf 'push:%s\nswitch:pool actually changed:%s\npush:%s\nswitch:restore reverts the pool to the backed-up value:Main' \
            "$alternate" "$(pool_label "$alternate")" "$alternate")"
done

for pool in main mini nano; do
    assert_eq "scenario override selects $pool from a sparse baseline" \
        "$(drive_pool scenario '{}' "p2pool.pool=$pool")" \
        "$(printf 'push:%s\nready:180:%s' "$pool" "$(pool_label "$pool")")"
done

echo "selftest-pool-defaults: $IT_PASS passed, $IT_FAIL failed"
[ "$IT_FAIL" -eq 0 ] || exit 1
