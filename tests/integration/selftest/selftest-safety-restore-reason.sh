#!/usr/bin/env bash
#
# Self-test for safety_restore_exact naming WHICH check failed (#2062, #2362).
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
export TMPDIR="${TMPDIR:-${RUNNER_TEMP:?}}"

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
        BASELINE_CONFIG='baseline' BASELINE_EXACT_SECRET_FP=$'wallet=wallet-before\nproxy=proxy-before'
        _restore_rc="$1" _up_rc="$2" _health_rc="$3" _config_state="${4:-match}" _secret_state="${5:-match}"
        pithead() {
            case "$1" in
            down) return 0 ;;
            restore) return "$_restore_rc" ;;
            up) return 0 ;;
            esac
        }
        baseline_up() { return "$_up_rc"; }
        wait_status_ok() { return "$_health_rc"; }
        rx() { [ "$_config_state" = match ] && printf 'baseline' || printf 'drifted'; }
        upgrade_secret_fingerprints() {
            case "$_secret_state" in
            match) printf '%s\n' "$BASELINE_EXACT_SECRET_FP" ;;
            drift) printf '%s\n' 'wallet=wallet-after' 'proxy=proxy-before' ;;
            *) return 1 ;;
            esac
        }
        it_log() { :; }
        safety_restore_exact >/dev/null 2>&1
        printf '%s' "$SAFETY_RESTORE_FAIL_REASON"
    )
}

echo "== safety_restore_exact names which check failed, not a generic verdict (#2062, #2362) =="

assert_eq "restore failure is named" "$(_restore_reason 1 0 0 match match)" "pithead restore failed"
assert_eq "startup failure is named" "$(_restore_reason 0 1 0 match match)" "stack did not come back up"
assert_eq "health failure is named" "$(_restore_reason 0 0 1 match match)" "pithead status did not become healthy within 240s"
assert_eq "a healthy restore leaves no reason" "$(_restore_reason 0 0 0 match match)" ""
assert_eq "a config drift is named, distinctly from restore/secrets" \
    "$(_restore_reason 0 0 0 drift match)" "restored config.json does not match the baseline byte-for-byte"
assert_eq "a secret drift is named, distinctly from restore/config" \
    "$(_restore_reason 0 0 0 match drift)" "restored secret categories do not match the baseline: wallet"
assert_eq "an unreadable secret category is named" \
    "$(_restore_reason 0 0 0 match unreadable)" "restored secret categories are unreadable"

_safety_backup_recovery_case() { # <healthy|normal|mkdir-fail|command-fail|redactor-fail>
    (
        local mode="$1" td wait_calls=0 restore_calls=0 cleanup_calls=0 capture_started=0
        td="$(mktemp -d)" && trap 'rm -rf "$td"' EXIT
        SAFETY_BACKUP=1 RUN_IMAGE_UPGRADE=0 OUT_DIR="$td/results" IT_PITHEAD=pithead
        SAFETY_ARCHIVE="$td/archive" SAFETY_RESTORE_FAILED=0
        command mkdir -p "$OUT_DIR"
        pithead() { [ "$1" = backup ] && printf 'Backup written to: %s\n' "$SAFETY_ARCHIVE"; }
        mkdir() {
            capture_started=1
            [ "$mode" != mkdir-fail ] && command mkdir "$@"
        }
        rx() {
            printf '%s\n' "$1" >>"$td/rx"
            case "$1" in
            'test -f'*) return 0 ;;
            tar*) printf 'config.json\n.env\n' ;;
            *'docker compose ps')
                [ "$mode" = command-fail ] && return 1
                printf 'tor unhealthy token=secret\n'
                ;;
            *status) printf 'status unhealthy token=secret\n' ;;
            *) return 1 ;;
            esac
        }
        redact() {
            printf 'redact\n' >>"$td/redactor"
            [ "$mode" != redactor-fail ] && sed 's/secret/<redacted>/g'
        }
        assert_contains() { :; }
        wait_status_ok() {
            wait_calls=$((wait_calls + 1))
            [ "$mode" = healthy ]
        }
        it_log() { :; }
        it_fail() { :; }
        safety_restore_exact() {
            restore_calls=$((restore_calls + 1))
            [ "$capture_started" = 1 ] &&
                { [ "$mode" = mkdir-fail ] || [ "$(wc -l <"$td/redactor")" -eq 2 ]; }
        }
        safety_cleanup() { cleanup_calls=$((cleanup_calls + 1)); }
        if [ "$mode" = healthy ]; then
            safety_backup &&
                [ ! -e "$OUT_DIR/safety-backup-recovery" ] &&
                [ "$wait_calls:$restore_calls:$cleanup_calls" = 1:0:0 ] &&
                [ "$(wc -l <"$td/rx")" -eq 2 ]
        else
            ! safety_backup &&
                [ "$wait_calls:$restore_calls:$cleanup_calls" = 1:1:1 ] &&
                [ "$capture_started" = 1 ] && {
                [ "$(wc -l <"$td/rx")" -eq "$([ "$mode" = mkdir-fail ] && echo 2 || echo 4)" ] &&
                    case "$mode" in
                    mkdir-fail) [ ! -e "$OUT_DIR/safety-backup-recovery" ] ;;
                    normal)
                        grep -q '<redacted>' "$OUT_DIR/safety-backup-recovery/compose-ps.txt" &&
                            grep -q '<redacted>' "$OUT_DIR/safety-backup-recovery/health-check.txt" &&
                            ! grep -R -q secret "$OUT_DIR/safety-backup-recovery"
                        ;;
                    command-fail)
                        [ ! -s "$OUT_DIR/safety-backup-recovery/compose-ps.txt" ] &&
                            grep -q '<redacted>' "$OUT_DIR/safety-backup-recovery/health-check.txt" &&
                            ! grep -R -q secret "$OUT_DIR/safety-backup-recovery"
                        ;;
                    redactor-fail)
                        [ ! -s "$OUT_DIR/safety-backup-recovery/compose-ps.txt" ] &&
                            [ ! -s "$OUT_DIR/safety-backup-recovery/health-check.txt" ]
                        ;;
                    esac
            }
        fi
    )
}

if _safety_backup_recovery_case healthy &&
    _safety_backup_recovery_case normal &&
    _safety_backup_recovery_case mkdir-fail &&
    _safety_backup_recovery_case command-fail &&
    _safety_backup_recovery_case redactor-fail; then
    it_pass "safety-backup recovery diagnostics are failure-only, redacted, and best-effort"
else
    it_fail "safety-backup recovery diagnostics are failure-only, redacted, and best-effort"
fi

echo "== safety restore retains bounded redacted diagnostics without changing its verdict =="
(
    td=$(mktemp -d "${TMPDIR:?}/restore-diagnostics.XXXXXX")
    trap 'find "$td" -depth -delete' EXIT
    OUT_DIR="$td/results" SAFETY_ARCHIVE="$td/archive" SAFETY_RESTORE_FAILED=0
    mkdir -p "$OUT_DIR"
    : >"$OUT_DIR/safety-restore.log"
    chmod 644 "$OUT_DIR/safety-restore.log"
    printf -v IT_DASHBOARD_PASSWORD '%s' fixture-restore-secret
    printf -v BASELINE_CONFIG '%s' baseline
    BASELINE_EXACT_SECRET_FP="$BASELINE_CONFIG"
    pithead() {
        if [ "$1" = restore ]; then
            awk 'BEGIN { for (i=0; i<5000; i++) print "restore filler line" }'
            printf '\nrestore diagnostic: %s\n' "$IT_DASHBOARD_PASSWORD" >&2
            return "$fixture_restore_rc"
        fi
    }
    baseline_up() { :; }
    wait_status_ok() { :; }
    rx() { printf baseline; }
    upgrade_secret_fingerprints() { printf baseline; }
    it_log() { :; }
    for fixture_restore_rc in 0 17; do
        SAFETY_RESTORE_FAILED=0
        actual_rc=0
        safety_restore_exact || actual_rc=$?
        [ "$actual_rc" = "$((fixture_restore_rc != 0))" ] || exit 1
        [ -s "$OUT_DIR/safety-restore.log" ] || exit 1
        [ "$(wc -c <"$OUT_DIR/safety-restore.log")" -eq 65536 ] || exit 1
        [ "$(stat -c %a "$OUT_DIR/safety-restore.log" 2>/dev/null || stat -f %Lp "$OUT_DIR/safety-restore.log")" = 600 ] || exit 1
        grep -Fq 'restore diagnostic: <redacted>' "$OUT_DIR/safety-restore.log" || exit 1
        if grep -Fq "$IT_DASHBOARD_PASSWORD" "$OUT_DIR/safety-restore.log"; then exit 1; fi
    done
    for diagnostic_case in path-fail redact-fail temp-fail; do
        (
            OUT_DIR="$td/$diagnostic_case"
            case "$diagnostic_case" in
            path-fail) : >"$OUT_DIR" ;;
            redact-fail) redact() { return 1; } ;;
            temp-fail) mktemp() { return 1; } ;;
            esac
            for fixture_restore_rc in 0 17; do
                actual_rc=0
                safety_restore_exact || actual_rc=$?
                [ "$actual_rc" = "$((fixture_restore_rc != 0))" ] || exit 1
            done
        ) || exit 1
    done
) && it_pass "restore diagnostics retain the error, redact credentials, bound output and preserve verdicts" ||
    it_fail "restore diagnostics retain the error, redact credentials, bound output and preserve verdicts"

echo "== hardening exercises a verified safety restore even when its earlier rows passed =="
(
    SAFETY_BACKUP=1 SAFETY_ARCHIVE=fixture
    for RUN_HARDENING in 0 1; do
        for initial_fails in 0 1; do
            (
                IT_FAIL="$initial_fails" called=0 passed=0
                it_warn() { :; }
                it_pass() { passed=$((passed + 1)); }
                safety_restore_exact() { called=$((called + 1)); }
                safety_rollback_if_failed || exit 1
                expected=$((RUN_HARDENING || initial_fails))
                [ "$called" = "$expected" ] && [ "$passed" = "$expected" ] || exit 1
            ) || exit 1
        done
    done
) && it_pass "hardening and failed runs prove the safety archive restore" ||
    it_fail "hardening and failed runs prove the safety archive restore"

echo "selftest-safety-restore-reason: $IT_PASS passed, $IT_FAIL failed"
[ "$IT_FAIL" -eq 0 ] || exit 1
