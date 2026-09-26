#!/usr/bin/env bash
#
# Self-test for #2757: a failed safety backup names its exit status and its last output lines.
# Job 1283 died on a bare "pithead backup failed." because backup_stack sent the output to
# /dev/null. backup_stack is extracted out of the shipped e2e.sh and run against a stub on_bench.
#
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/integration/lib.sh
source "$HERE/../lib.sh"

echo "== backup_stack names why the safety backup failed =="
SRC="$(sed -n '/^backup_stack() {$/,/^}$/p' "$HERE/../e2e.sh")"
assert_eq "the extraction is the whole function (opens and closes)" \
    "$(printf '%s\n' "$SRC" | sed -n '1p;$p' | tr '\n' ' ')" "backup_stack() { } "

out="$(
    # shellcheck disable=SC2034,SC2329  # used by the eval'd backup_stack
    {
        CANONICAL_DIR=/srv/x
        log() { :; }
        ok() { :; }
        warn() { echo "$*"; }
        die() {
            echo "DIE $*"
            exit 1
        }
        redact_remote_output() { cat; }
        on_bench() {
            printf 'step one\nError: disk full writing archive\n'
            return 3
        }
        eval "$SRC"
        backup_stack
    } 2>&1
)"

assert_contains "the failure names the exit status" "$out" "DIE pithead backup failed (exit 3): step one|Error: disk full writing archive"
assert_contains "the failure shows the backup's own error line" "$out" "Error: disk full writing archive"

echo ""
printf 'backup-reason self-test: %s passed, %s failed\n' "$IT_PASS" "$IT_FAIL"
[ "$IT_FAIL" -eq 0 ]
