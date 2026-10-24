#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/integration/lib.sh
source "$HERE/../lib.sh"
INTEGRATION_RUN_SUITE=1
# shellcheck source=tests/integration/lib/run-safety.sh
source "$HERE/../lib/run-safety.sh"
echo "== restore operations retain sanitized originating diagnostics through cleanup =="
fixture="$(mktemp -d)"
trap 'rm -rf -- "$fixture"' EXIT
OUT_DIR="$fixture/results"
mkdir "$OUT_DIR"

changed=0
sample='fixture-stratum'
failed_operation() {
    changed=1
    printf '%s\n' 'origin stdout' 'PASSWORD=changeme' "Stratum password: $sample" "every rig must connect with pass \"$sample\" (set it)"
    printf '%s\n' 'origin stderr' 'endpoint 192.0.2.1' >&2
    return 73
}
operation_rc=0
restore_operation fixture.restore failed_operation || operation_rc=$?
[ "$operation_rc:$changed" = 73:1 ]
grep -q 'operation=fixture.restore exit=73' "$OUT_DIR/restore-operations.log"
grep -q 'origin stdout' "$OUT_DIR/restore-operations.log"
grep -q 'origin stderr' "$OUT_DIR/restore-operations.log"
grep -q 'PASSWORD=<redacted>' "$OUT_DIR/restore-operations.log"
grep -q 'Stratum password: <redacted>' "$OUT_DIR/restore-operations.log"
grep -q 'connect with pass <redacted>' "$OUT_DIR/restore-operations.log"
! grep -Eq 'changeme|fixture-stratum|192[.]0[.]2[.]1' "$OUT_DIR/restore-operations.log"

(
    redact() { return 1; }
    operation_rc=0
    restore_operation fixture.redactor failed_operation 2>"$fixture/capture-error" || operation_rc=$?
    grep -q 'restore diagnostic: fixture.redactor artifact unavailable (exit 73)' "$fixture/capture-error"
    [ "$operation_rc:$changed" = 73:1 ]
    ! grep -q changeme "$OUT_DIR/restore-operations.log"
)
(
    OUT_DIR="$fixture/missing"
    changed=0 operation_rc=0
    restore_operation fixture.no-artifact failed_operation 2>"$fixture/capture-error" || operation_rc=$?
    grep -q 'restore diagnostic: fixture.no-artifact artifact unavailable (exit 73)' "$fixture/capture-error"
    [ "$operation_rc:$changed" = 73:1 ]
)

python3 - "$HERE/../lib.sh" "$OUT_DIR" "$fixture" <<'PYTHON'
import os
import subprocess
import sys
from pathlib import Path

root = Path(sys.argv[3])
scratch = root / "interruption-scratch"
scratch.mkdir()
script = r'''source "$1"
recovery_marker="$3/interruption-recovery"
trap 'printf recovered >"$recovery_marker"' EXIT
OUT_DIR="$2"
restore_operation fixture.interrupted bash -c 'sample=interrupted-secret; printf "%s\n" "Stratum password: $sample"; kill -TERM "$PPID"; exit 78'
'''
result = subprocess.run(
    ["bash", "-c", script, "bash", *sys.argv[1:]],
    env={**os.environ, "TMPDIR": str(scratch)},
    capture_output=True,
    timeout=10,
)
assert result.returncode in (-15, 143), result.returncode
assert (root / "interruption-recovery").read_text() == "recovered"
assert not list(scratch.iterdir())
assert "interrupted-secret" not in (Path(sys.argv[2]) / "restore-operations.log").read_text()
PYTHON

for failing_stage in config-write apply health; do
    (
        : >"$OUT_DIR/restore-operations.log"
        BASELINE_CONFIG=baseline BASELINE_SECRET_FP="$sample" KEEP_STATE=0 SAFETY_RESTORE_FAILED=0
        calls=""
        step() {
            calls="${calls:+$calls,}$1"
            printf 'output %s\n' "$1"
            printf 'stderr %s %s\n' "$1" 'PASSWORD=changeme' >&2
            [ "$1" != "$failing_stage" ] || return 75
        }
        push_config() { step config-write; }
        pithead() { step "$1"; }
        wait_status_ok() { step health; }
        it_log() { :; }
        it_fail() { :; }
        operation_rc=0
        restore_baseline || operation_rc=$?
        [ "$operation_rc:$SAFETY_RESTORE_FAILED" = 1:1 ]
        case "$failing_stage:$calls" in
        config-write:config-write | apply:config-write,apply | health:config-write,apply,health) ;;
        *) exit 1 ;;
        esac
        grep -q "operation=baseline.$failing_stage exit=75" "$OUT_DIR/restore-operations.log"
        grep -q "output $failing_stage" "$OUT_DIR/restore-operations.log"
        grep -q "stderr $failing_stage PASSWORD=<redacted>" "$OUT_DIR/restore-operations.log"
        ! grep -q changeme "$OUT_DIR/restore-operations.log"
    )
done

for failing_stage in down restore up health; do
    (
        : >"$OUT_DIR/restore-operations.log"
        BASELINE_CONFIG=baseline BASELINE_EXACT_SECRET_FP="$sample"
        SAFETY_ARCHIVE=retained-archive SAFETY_RESTORE_FAILED=0
        calls=""
        step() {
            calls="${calls:+$calls,}$1"
            printf 'output %s\n' "$1"
            printf 'stderr %s %s\n' "$1" 'PASSWORD=changeme' >&2
            [ "$1" != "$failing_stage" ] || return 76
        }
        pithead() {
            if [ "$1" = up ]; then
                step recovery-up
                return 77
            fi
            step "$1"
        }
        baseline_up() { step up; }
        wait_status_ok() { step health; }
        rx() { printf baseline; }
        upgrade_secret_fingerprints() { printf '%s' "$BASELINE_EXACT_SECRET_FP"; }
        it_log() { :; }
        operation_rc=0
        safety_restore_exact || operation_rc=$?
        grep -q "operation=safety-restore.$failing_stage exit=76" "$OUT_DIR/restore-operations.log"
        grep -q "stderr $failing_stage PASSWORD=<redacted>" "$OUT_DIR/restore-operations.log"
        [ "$SAFETY_ARCHIVE" = retained-archive ]
        if [ "$failing_stage" = down ]; then
            [ "$operation_rc:$SAFETY_RESTORE_FAILED" = 0:0 ]
        else
            [ "$operation_rc:$SAFETY_RESTORE_FAILED" = 1:1 ]
            grep -q 'operation=safety-recovery.up exit=77' "$OUT_DIR/restore-operations.log"
            [ -n "$SAFETY_RESTORE_FAIL_REASON" ]
            case "$failing_stage:$calls" in
            restore:down,restore,recovery-up,health | up:down,restore,up,recovery-up,health | health:down,restore,up,health,recovery-up,health) ;;
            *) exit 1 ;;
            esac
        fi
        ! grep -q changeme "$OUT_DIR/restore-operations.log"
    )
done

IT_MODE=local IT_REMOTE_DIR="$fixture"
IT_SSH_OPTS=()
run_restore_diagnostic_control
[ "$IT_FAIL" = 0 ]
grep -q 'operation=control.restore exit=73' "$OUT_DIR/restore-diagnostic-control/restore-operations.log"
grep -q 'operation=control.cleanup exit=74' "$OUT_DIR/restore-diagnostic-control/restore-operations.log"
(
    restore_operation() { return 0; }
    if run_restore_diagnostic_control; then exit 1; fi
)
printf '%s\n' 'restore diagnostic controls passed'
