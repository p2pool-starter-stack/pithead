#!/usr/bin/env bash
set -uo pipefail
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HERE="$SELF/.."
# shellcheck source=tests/integration/lib.sh
source "$HERE/lib.sh"
INTEGRATION_RUN_SUITE=1
# shellcheck source=tests/integration/lib/run-safety.sh
source "$HERE/lib/run-safety.sh"

echo "== restore_baseline names which step failed and keeps its sanitized output (#3641) =="

_baseline_case() { # <config-rc> <apply-rc> <health-rc> -> reason|SAFETY_RESTORE_FAILED[|apply-log]
    (
        KEEP_STATE=0 BASELINE_CONFIG='baseline' BASELINE_SECRET_FP=fp SAFETY_RESTORE_FAILED=0
        td="$(mktemp -d)" || exit 1
        trap 'cd / && rm -rf "$td"' EXIT
        cd "$td" || exit 1
        OUT_DIR=results
        _config_rc="$1" _apply_rc="$2" _health_rc="$3"
        push_config() { return "$_config_rc"; }
        pithead() {
            [ "$1" = apply ] && printf 'apply-boom PASSWORD=fixture-secret\n'
            return "$_apply_rc"
        }
        wait_status_ok() { return "$_health_rc"; }
        rx() { printf 'baseline'; }
        secret_fingerprint() { printf 'fp'; }
        it_log() { :; }
        it_pass() { :; }
        _reason=""
        it_fail() { _reason="$2"; }
        restore_baseline >/dev/null 2>&1
        printf '%s|%s' "$_reason" "$SAFETY_RESTORE_FAILED"
        if [ "${STEP_LOGS:-no}" = yes ] && [ -s results/baseline-restore/apply.log ]; then
            printf '|%s' "$(tr '\n' '~' <results/baseline-restore/apply.log)"
        fi
    )
}

assert_eq "a healthy baseline restore records no failure" "$(_baseline_case 0 0 0)" "|0"
assert_eq "a failed config write is named with its rc and log (#3641)" \
    "$(_baseline_case 1 0 0)" \
    "config write returned non-zero (rc 1); see results/baseline-restore/config-write.log; safety archive retained|1"
assert_eq "a failed apply is named with its rc and log (#3641)" \
    "$(_baseline_case 0 1 0)" \
    "pithead apply returned non-zero (rc 1); see results/baseline-restore/apply.log; safety archive retained|1"
assert_eq "a failed health wait is named as health and points at the apply log (#3641)" \
    "$(_baseline_case 0 0 1)" \
    "pithead status did not become healthy within 240s; see results/baseline-restore/apply.log for the apply; safety archive retained|1"
assert_eq "the failed baseline apply keeps its sanitized output (#3641)" \
    "$(STEP_LOGS=yes _baseline_case 0 1 0)" \
    "pithead apply returned non-zero (rc 1); see results/baseline-restore/apply.log; safety archive retained|1|apply-boom PASSWORD=<redacted>~"
case "$(STEP_LOGS=yes _baseline_case 0 1 0)" in
*fixture-secret*) it_fail "the retained baseline-apply log drops the planted secret value (#3641)" ;;
*) it_pass "the retained baseline-apply log drops the planted secret value (#3641)" ;;
esac

echo "selftest-baseline-restore-reason: $IT_PASS passed, $IT_FAIL failed"
[ "$IT_FAIL" -eq 0 ] || exit 1
