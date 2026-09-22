#!/usr/bin/env bash
#
# Self-test for safety_restore_exact naming WHICH check failed (#2062).
#
# The function used to fold five independent failure points (restore, up, health, config,
# secrets) into one boolean via a chained `||`, so every rollback failure reported the same
# generic "restore/apply/health/config/secret verification failed" — job 510 hit this reading a
# real appliance-channel rollback failure and there was no way to tell which check actually
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

_restore_reason() { # <pithead-restore-rc> <config: match|drift> <secrets: match|drift>
    (
        SAFETY_ARCHIVE=/tmp/a.tar.gz SAFETY_RESTORE_FAILED=0 SAFETY_RESTORE_FAIL_REASON=""
        BASELINE_CONFIG='baseline' BASELINE_EXACT_SECRET_FP='fp'
        _restore_rc="$1" _config_state="${2:-match}" _secret_state="${3:-match}"
        pithead() {
            case "$1" in
            down) return 0 ;;
            restore) return "$_restore_rc" ;;
            up) return 0 ;;
            esac
        }
        strict_pithead() { return 0; }
        wait_status_ok() { return 0; }
        rx() { [ "$_config_state" = match ] && printf 'baseline' || printf 'drifted'; }
        upgrade_secret_fingerprints() { [ "$_secret_state" = match ] && printf fp || printf other; }
        it_log() { :; }
        safety_restore_exact >/dev/null 2>&1
        printf '%s' "$SAFETY_RESTORE_FAIL_REASON"
    )
}

echo "== safety_restore_exact names which check failed, not a generic verdict (#2062) =="

assert_eq "restore failure is named" "$(_restore_reason 1 match match)" "pithead restore failed"
assert_eq "a healthy restore leaves no reason" "$(_restore_reason 0 match match)" ""
assert_eq "a config drift is named, distinctly from restore/secrets" \
    "$(_restore_reason 0 drift match)" "restored config.json does not match the baseline byte-for-byte"
assert_eq "a secret drift is named, distinctly from restore/config" \
    "$(_restore_reason 0 match drift)" "restored wallet/proxy/dashboard/RPC/onion secrets do not match the baseline"

_safety_backup_recovery_capture() {
    (
        OUT_DIR="$(mktemp -d)" SAFETY_BACKUP=1 RUN_IMAGE_UPGRADE=0
        SAFETY_ARCHIVE="" SAFETY_RESTORE_FAILED=0 events=""
        pithead() {
            [ "$1" = backup ] && {
                printf 'Backup written to: /tmp/safety.tar.gz\n'
                return 0
            }
        }
        rx() {
            case "$1" in
            test\ -f*) return 0 ;;
            tar\ -tzf*) printf 'config.json\n.env\n' ;;
            docker\ compose\ ps*) printf 'unhealthy PASSWORD=secret\n' ;;
            esac
        }
        wait_status_ok() { return 1; }
        capture_artifacts() {
            mkdir -p "$2/$1"
            events="${events}capture:$1 "
        }
        safety_restore_exact() { events="${events}restore "; }
        safety_cleanup() { events="${events}cleanup "; }
        it_log() { :; }
        it_fail() { :; }
        assert_contains() { :; }
        safety_backup
        rc=$?
        healthcheck="$(cat "$OUT_DIR/safety-backup/healthcheck.txt")"
        rm -rf "$OUT_DIR"
        printf '%s|%s|%s' "$rc" "$events" "$healthcheck"
    )
}

assert_eq "failed safety-backup recovery captures diagnostics before restore" \
    "$(_safety_backup_recovery_capture)" "1|capture:safety-backup restore cleanup |unhealthy PASSWORD=<redacted>"

echo "selftest-safety-restore-reason: $IT_PASS passed, $IT_FAIL failed"
[ "$IT_FAIL" -eq 0 ] || exit 1
