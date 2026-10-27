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
        printf '%s' "${4:-$BASELINE_CONFIG}" >"$OUT_DIR/current-config"
        : >"$TRACE"
        it_log() { :; }
        it_step() { :; }
        it_pass() { :; }
        it_skip_leg() { :; }
        it_fail() { printf 'failure:%s\n' "$1" >>"$TRACE"; }
        pithead() {
            [ "${POOL_APPLY_FAIL:-}:$1" != 1:apply ] || return 1
            [ "$1" != apply ] || cp "$OUT_DIR/pending-config" "$OUT_DIR/current-config"
        }
        wait_status_ok() { :; }
        wait_monero_synced() { :; }
        secret_fingerprint() { printf 'test-fingerprint'; }
        upgrade_secret_fingerprints() {
            if [ -f "$OUT_DIR/pending-config" ]; then
                case "${POOL_SECRET_CASE:-}" in
                after-fails) return 1 ;;
                after-empty) return 0 ;;
                after-changed) printf changed; return 0 ;;
                esac
            else
                case "${POOL_SECRET_CASE:-}" in
                before-fails) return 1 ;;
                before-empty) return 0 ;;
                esac
            fi
            printf test-fingerprint
        }
        env_on_box() {
            if [ "$1" = DASHBOARD_SECURE ]; then
                printf false
            elif [ "${POOL_APPLY_FAIL:-}" = 1 ]; then
                printf '%s' "$OUT_DIR/owner"
            fi
        }
        has_compose_profile() { [ "${POOL_APPLY_FAIL:-}" = 1 ]; }
        run_cli_wizard_defaults() { :; }
        lifecycle_gate_sample() { :; }
        run_source_image_reconcile() { :; }
        run_tari_background_sync() { :; }
        sync_gate_marker_state() { printf absent; }
        run_connection_announcements() { :; }
        tor_recovery_healthy_probe() { :; }
        run_reset_restore() { :; }
        run_uninstall_round_trip() { :; }
        assert_scenario() { :; }
        restore_firewall_after_clearnet() { :; }
        assert_rc() { :; }
        assert_eq() { :; }
        wait_for() {
            shift 3
            [ "$1" != lifecycle_pool_flags_match ] || "$@"
        }
        api_state() { printf '{"pool":{"type":"Main"}}'; }
        rx() {
            case "$1" in
            jq*) jq -er '.p2pool.pool // "mini"' "$OUT_DIR/current-config" ;;
            "grep -qE "*) return 0 ;;
            "grep -E '^P2POOL_FLAGS='"*)
                case "$(jq -r '.p2pool.pool // "mini"' "$OUT_DIR/current-config")" in
                mini) printf '%s' '--mini' ;;
                nano) printf '%s' '--nano' ;;
                main) printf '%s' '--host fixture' ;;
                esac
                ;;
            'test -f dashboard/Dockerfile') return 1 ;;
            "sudo rm -f "*) printf 'owner-probe-cleaned\n' >>"$TRACE" ;;
            ls*) printf 'backups/test.tar.gz' ;;
            esac
        }
        push_config() {
            printf '%s' "$1" >"$OUT_DIR/pending-config"
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

assert_eq "lifecycle switches from the preceding Main scenario rather than its saved Mini baseline" \
    "$(drive_pool lifecycle '{"p2pool":{"pool":"mini"}}' '' '{"p2pool":{"pool":"main"}}')" \
    "$(printf 'push:mini\nswitch:pool actually changed:Mini\npush:mini\nswitch:restore reverts the pool to the backed-up value:Main')"
assert_eq "lifecycle switches from a sparse Mini scenario rather than its saved Main baseline" \
    "$(drive_pool lifecycle '{"p2pool":{"pool":"main"}}' '' '{}')" \
    "$(printf 'push:main\nswitch:pool actually changed:Main\npush:main\nswitch:restore reverts the pool to the backed-up value:Main')"
assert_eq "a failed pool apply removes the ownership probe before stopping lifecycle" \
    "$(POOL_APPLY_FAIL=1 drive_pool lifecycle '{"p2pool":{"pool":"mini"}}')" \
    "$(printf 'push:main\nfailure:pool change apply returned healthy\nowner-probe-cleaned')"

for failure in before-fails before-empty; do
    assert_eq "an unreadable starting categorized fingerprint stops before pushing ($failure)" \
        "$(POOL_SECRET_CASE="$failure" drive_pool lifecycle '{"p2pool":{"pool":"mini"}}')" \
        'failure:pool change starting secrets readable'
done
for failure in after-fails after-empty after-changed; do
    assert_eq "an unreadable or changed categorized fingerprint stops lifecycle ($failure)" \
        "$(POOL_SECRET_CASE="$failure" drive_pool lifecycle '{"p2pool":{"pool":"mini"}}')" \
        "$(printf 'push:main\nfailure:secrets preserved across pool change')"
done

for pool in main mini nano; do
    assert_eq "scenario override selects $pool from a sparse baseline" \
        "$(drive_pool scenario '{}' "p2pool.pool=$pool")" \
        "$(printf 'push:%s\nready:180:%s' "$pool" "$(pool_label "$pool")")"
done

echo "selftest-pool-defaults: $IT_PASS passed, $IT_FAIL failed"
[ "$IT_FAIL" -eq 0 ] || exit 1
