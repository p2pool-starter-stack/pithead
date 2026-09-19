#!/usr/bin/env bash
#
# Self-test for safety_restore_exact naming WHICH check failed (#2362).
#
# The function used to fold five independent failure points (restore, up, health, config,
# secrets) into one boolean via a chained `||`, so every rollback failure reported the same
# generic "restore/apply/health/config/secret verification failed" — job 510 hit this reading a
# real tier4 rollback failure and there was no way to tell which check actually
# failed from the log. Fixed by testing each disjunct in order and recording which one fired in
# SAFETY_RESTORE_FAIL_REASON; this file pins that each failure mode is named distinctly.
#
# A separate file because selftest-live-gates.sh, which already exercises
# safety_restore_exact's stack-recovery behaviour, sits ON its lint-file-budget ceiling (453);
# the runner globs `selftest*.sh` (Makefile:43), so a new file needs no registration.
#
# Run: tests/integration/selftest/selftest-safety-restore-reason.sh
set -uo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The modules resolve their own siblings off $HERE, which is the harness root, not selftest/.
HERE="$SELF/.."
# shellcheck source=tests/integration/lib.sh
source "$HERE/lib.sh"
# run-safety.sh carries the suite guard; this self-test IS a suite consumer of it.
INTEGRATION_RUN_SUITE=1
# shellcheck source=tests/integration/lib/run-safety.sh
source "$HERE/lib/run-safety.sh"

_restore_reason() { # <restore-rc> <up-rc> <health-rc> <config: match|drift> <secrets: match|drift>
    (
        SAFETY_ARCHIVE=/tmp/a.tar.gz SAFETY_RESTORE_FAILED=0 SAFETY_RESTORE_FAIL_REASON=""
        BASELINE_CONFIG='baseline' BASELINE_EXACT_SECRET_FP='fp'
        _restore_rc="$1" _up_rc="$2" _health_rc="$3" _config_state="${4:-match}" _secret_state="${5:-match}"
        pithead() {
            case "$1" in
            down) return 0 ;;
            restore) return "$_restore_rc" ;;
            up) return 0 ;;
            esac
        }
        strict_pithead() { return "$_up_rc"; }
        wait_status_ok() { return "$_health_rc"; }
        rx() { [ "$_config_state" = match ] && printf 'baseline' || printf 'drifted'; }
        upgrade_secret_fingerprints() { [ "$_secret_state" = match ] && printf fp || printf other; }
        it_log() { :; }
        safety_restore_exact >/dev/null 2>&1
        printf '%s' "$SAFETY_RESTORE_FAIL_REASON"
    )
}

echo "== safety_restore_exact names which check failed, not a generic verdict (#2362) =="

assert_eq "restore failure is named" "$(_restore_reason 1 0 0 match match)" "pithead restore failed"
assert_eq "startup failure is named" "$(_restore_reason 0 1 0 match match)" "stack did not come back up"
assert_eq "health failure is named" "$(_restore_reason 0 0 1 match match)" "pithead status did not become healthy within 240s"
assert_eq "a healthy restore leaves no reason" "$(_restore_reason 0 0 0 match match)" ""
assert_eq "a config drift is named, distinctly from restore/secrets" \
    "$(_restore_reason 0 0 0 drift match)" "restored config.json does not match the baseline byte-for-byte"
assert_eq "a secret drift is named, distinctly from restore/config" \
    "$(_restore_reason 0 0 0 match drift)" "restored wallet/proxy/dashboard/RPC/onion secrets do not match the baseline"

echo "selftest-safety-restore-reason: $IT_PASS passed, $IT_FAIL failed"
[ "$IT_FAIL" -eq 0 ] || exit 1
