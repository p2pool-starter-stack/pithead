#!/usr/bin/env bash
# A failed backup restore must stop later faults before they touch an unhealthy stack (#2501).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/integration/lib.sh
source "$HERE/../lib.sh"

echo "== lifecycle restore health gates fault injection (#2501) =="

LIFECYCLE_SRC="$(sed -n '/^run_lifecycle() {$/,/^}$/p' "$HERE/../lib/run-lifecycle.sh")"
assert_eq "the extraction is the whole lifecycle function" \
    "$(printf '%s\n' "$LIFECYCLE_SRC" | sed -n '1p;$p' | tr '\n' ' ')" "run_lifecycle() { } "

drive_restore() { # <healthy: yes|no> [*-fails|archive-missing|verify-fails] -> function-rc|failure-count
    (
        # shellcheck disable=SC2034 # read by the extracted lifecycle function via eval
        IT_FAIL=0 BASELINE_CONFIG='{}' RESTORE_HEALTHY="$1" RESTORE_CASE="${2:-}" PUSH_COUNT=0 RESTORED=no
        it_log() { :; }
        it_step() { :; }
        it_pass() { :; }
        it_skip_leg() { :; }
        it_fail() { IT_FAIL=$((IT_FAIL + 1)); }
        pithead() {
            case "$RESTORE_CASE:$1" in
            backup-fails:backup | apply-fails:apply | down-fails:down | restore-fails:restore | up-fails:up) return 1 ;;
            esac
            [ "$1" != restore ] || RESTORED=yes
        }
        wait_status_ok() { [ "$RESTORE_HEALTHY" = yes ]; }
        # carry-* cases also run the local-node legs, including the #2360 dashboard carry.
        env_on_box() { case "$RESTORE_CASE" in carry-*) printf /data/dashboard ;; esac }
        has_compose_profile() { case "$RESTORE_CASE" in carry-*) return 0 ;; *) return 1 ;; esac }
        wait_for() { :; }
        assert_rc() { :; }
        dashboard_durable_rows() { printf 'blocks -'; }
        telemetry_rows_continue() { :; }
        telemetry_rows_diff() { :; }
        jq_get() { [ -n "$1" ] && printf main; }
        api_state() { [ "$RESTORE_CASE" != pool-state-fails ] && printf '{}'; }
        secret_fingerprint() {
            case "$RESTORE_CASE:$RESTORED" in
            secret-before-fails:* | secret-after-fails:yes) return 1 ;;
            esac
            printf fingerprint
        }
        render_scenario_config() { printf '{}'; }
        push_config() {
            PUSH_COUNT=$((PUSH_COUNT + 1))
            [ "$RESTORE_CASE" != push-config-fails ] || [ "$PUSH_COUNT" -ne 2 ]
        }
        assert_pool_switched() {
            [ "$RESTORE_CASE:$1" != "verify-fails:restore reverts the pool to the backed-up value" ] || it_fail
        }
        assert_eq() {
            [ "$RESTORE_CASE:$1" != "secret-fails:restore preserves secrets" ] || it_fail
        }
        quote_arg() { printf '%s' "$1"; }
        rx() {
            case "$1" in
            ls*) [ "$RESTORE_CASE" != archive-missing ] && printf 'backups/pithead-backup-test.tar.gz' ;;
            "rm -rf -- "*) [ "$RESTORE_CASE" != carry-cleanup-fails ] ;;
            esac
        }
        eval "$LIFECYCLE_SRC"
        run_lifecycle >/dev/null
        printf '%s|%s' "$?" "$IT_FAIL"
    )
}

assert_eq "a healthy restore succeeds" "$(drive_restore yes)" "0|0"
assert_eq "an unhealthy restore fails lifecycle" "$(drive_restore no)" "1|1"
assert_eq "a failed backup fails lifecycle" "$(drive_restore yes backup-fails)" "1|1"
assert_eq "a missing backup archive fails lifecycle" "$(drive_restore yes archive-missing)" "1|1"
assert_eq "a failed config push fails lifecycle" "$(drive_restore yes push-config-fails)" "1|1"
assert_eq "a failed apply fails lifecycle" "$(drive_restore yes apply-fails)" "1|1"
assert_eq "a failed down fails lifecycle" "$(drive_restore yes down-fails)" "1|1"
assert_eq "a failed restore fails lifecycle" "$(drive_restore yes restore-fails)" "1|1"
assert_eq "a failed up fails lifecycle" "$(drive_restore yes up-fails)" "1|1"
assert_eq "a failed restore verification fails lifecycle" "$(drive_restore yes verify-fails)" "1|1"
assert_eq "a failed restored-secret assertion fails lifecycle" "$(drive_restore yes secret-fails)" "1|1"
assert_eq "an unreadable backup secret fingerprint fails lifecycle" "$(drive_restore yes secret-before-fails)" "1|1"
assert_eq "an unreadable restored secret fingerprint fails lifecycle" "$(drive_restore yes secret-after-fails)" "1|1"
assert_eq "an unreadable backed-up pool state fails lifecycle" "$(drive_restore yes pool-state-fails)" "1|1"
assert_eq "a healthy dashboard carry keeps lifecycle passing (#2360)" "$(drive_restore yes carry-ok)" "0|0"
assert_eq "a failed dashboard carry cleanup fails lifecycle (#2360)" "$(drive_restore yes carry-cleanup-fails)" "1|1"

eval "$(sed -n '/^telemetry_rows_diff() {/,/^}$/p' "$HERE/../lib/run-lifecycle.sh")"
assert_eq "telemetry diff names the tables that lost rows" "$(telemetry_rows_diff $'blocks -\nblocks aaa\nkv_store-stable ccc\nkv_store-stable ddd' $'blocks -\nblocks aaa')" "before=4 after=2 missing: kv_store-stable x2"
assert_eq "telemetry diff reports an empty probe" "$(telemetry_rows_diff "" "")" "before=0 after=0 missing: none"

# The real fingerprint must fail closed: an unreadable or secret-less .env is not a fingerprint.
FP_SRC="$(sed -n '/^secret_fingerprint() {$/,/^}$/p' "$HERE/../lib/run-matrix.sh")"
assert_contains "the extraction is the real secret_fingerprint" "$FP_SRC" "sha256sum"
drive_fingerprint() { # <.env contents|-> -> zero|nonzero|output ("-" = no .env)
    (
        cd "$(mktemp -d)" || exit 1
        [ "$1" = - ] || printf '%s\n' "$1" >.env
        rx() { bash -c "$1"; }
        eval "$FP_SRC"
        rc=zero
        out="$(secret_fingerprint)" || rc=nonzero
        printf '%s|%s' "$rc" "$out"
    )
}
assert_eq "a missing .env gives no fingerprint" "$(drive_fingerprint -)" "nonzero|"
assert_eq "an .env without secrets gives no fingerprint" "$(drive_fingerprint 'P2POOL_FLAGS=--mini')" "nonzero|"
FP_OK="$(drive_fingerprint "$(printf 'PROXY_AUTH_TOKEN=t\nTOR_ONION_ADDRESS=x.onion')")"
if [[ "$FP_OK" =~ ^zero\|[0-9a-f]{64}$ ]]; then
    it_pass "an .env with secrets gives a 64-hex fingerprint"
else
    it_fail "an .env with secrets gives a 64-hex fingerprint" "got '$FP_OK'"
fi

MAIN_SRC="$(sed -n '/^    local lifecycle_ok=1$/,/^    \[ "\$rig_control_ok" = 1 \] && \[ "\$lifecycle_ok" = 1 \] && \[ "\$RUN_FAULTS" = "1" \] && run_fault_injection$/p' "$HERE/../run.sh")"
assert_contains "the extracted gate includes lifecycle and fault injection" "$MAIN_SRC" "run_fault_injection"

drive_gate() { # <lifecycle-rc> -> fault-ran
    (
        # shellcheck disable=SC2034 # read by the extracted run.sh gate via eval
        RUN_LIFECYCLE=1 RUN_FAULTS=1 rig_control_ok=1 fault_ran=no lifecycle_rc="$1"
        run_lifecycle() { return "$lifecycle_rc"; }
        run_fault_injection() { fault_ran=yes; }
        gate() { eval "$MAIN_SRC"; }
        gate >/dev/null 2>&1 || true
        printf '%s' "$fault_ran"
    )
}

assert_eq "fault injection runs after a healthy lifecycle" "$(drive_gate 0)" "yes"
assert_eq "fault injection is skipped after a failed lifecycle" "$(drive_gate 1)" "no"

echo "selftest-lifecycle-restore-health: $IT_PASS passed, $IT_FAIL failed"
[ "$IT_FAIL" -eq 0 ] || exit 1
