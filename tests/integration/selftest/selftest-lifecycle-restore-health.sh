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

drive_restore() { # <healthy: yes|no> -> function-rc|failure-count
    (
        # shellcheck disable=SC2034 # read by the extracted lifecycle function via eval
        IT_FAIL=0 BASELINE_CONFIG='{}' RESTORE_HEALTHY="$1"
        it_log() { :; }
        it_step() { :; }
        it_pass() { :; }
        it_skip_leg() { :; }
        it_fail() { IT_FAIL=$((IT_FAIL + 1)); }
        pithead() { return 0; }
        wait_status_ok() { [ "$RESTORE_HEALTHY" = yes ]; }
        env_on_box() { :; }
        has_compose_profile() { return 1; }
        jq_get() { printf main; }
        api_state() { printf '{}'; }
        secret_fingerprint() { printf fingerprint; }
        render_scenario_config() { printf '{}'; }
        push_config() { :; }
        assert_pool_switched() { :; }
        assert_eq() { :; }
        quote_arg() { printf '%s' "$1"; }
        rx() { case "$1" in ls*) printf 'backups/pithead-backup-test.tar.gz' ;; esac }
        eval "$LIFECYCLE_SRC"
        run_lifecycle >/dev/null
        printf '%s|%s' "$?" "$IT_FAIL"
    )
}

assert_eq "a healthy restore succeeds" "$(drive_restore yes)" "0|0"
assert_eq "an unhealthy restore fails lifecycle" "$(drive_restore no)" "1|1"

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
