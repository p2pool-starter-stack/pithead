#!/usr/bin/env bash
set -euo pipefail
export TMPDIR="${TMPDIR:-${RUNNER_TEMP:-/tmp}}"
HERE=$(cd "$(dirname "$0")" && pwd)
T=$(mktemp -d "${TMPDIR:?}/migration-release-wait.XXXXXX")
trap 'rm -rf "$T"' EXIT
fail() {
    echo "FAIL: $*" >&2
    exit 1
}
SCRIPT_DIR=$HERE
# shellcheck source=tests/os/migration-recovery.sh
source "$HERE/migration-recovery.sh"

sleep_calls=0
sleep() { sleep_calls=$((sleep_calls + 1)); }
_ssh() {
    case "$1" in
    *'-- slots --'*) cat "$T/evidence" ;;
    *'chain services released'*) grep -q 'chain services released' "$T/journal" ;;
    *'never became healthy'*)
        grep -E 'slot left uncommitted|never became healthy|this is failure|NOT a bad slot|migration marker could not be assigned' "$T/journal" |
            head -n1
        ;;
    *'grep -qx monerod'*) grep -qx monerod "$T/podman" ;;
    *) return 0 ;;
    esac
}
journal_has() { printf '%s\n' "$1" >"$T/journal"; }

: >"$T/journal"
: >"$T/podman"
journal_has 'pithead-boot: slot committed — chain services released, the data migration runs now'
MIGRATION_RELEASE_WAIT_ROUNDS=240
sleep_calls=0
migration_release_early=9
migration_release_wait || fail 'the release line must end the wait green'
[ "$migration_release_rounds" -eq 1 ] || fail 'the release check must run first in a round'
[ "$migration_release_early" = 0 ] || fail 'monerod beside a released boot is not early'
[ "$sleep_calls" -eq 0 ] || fail 'a released boot must not sleep a round'

: >"$T/journal"
printf 'monerod\n' >"$T/podman"
journal_has 'pithead-boot: the stack could not be brought up — slot left uncommitted so A/B fallback stays armed'
MIGRATION_RELEASE_WAIT_ROUNDS=240
sleep_calls=0
if migration_release_wait; then fail 'a dead boot must not report release'; fi
[ "$migration_release_line" = 'pithead-boot: the stack could not be brought up — slot left uncommitted so A/B fallback stays armed' ] ||
    fail "the terminal verdict lost the boot's line: $migration_release_line"
[ "$sleep_calls" -eq 0 ] || fail 'a dead boot must end the wait without another round'

: >"$T/journal"
: >"$T/podman"
MIGRATION_RELEASE_WAIT_ROUNDS=3
sleep_calls=0
if migration_release_wait; then fail 'a boot that logs nothing must fail at the bound'; fi
[ "$migration_release_rounds" -eq 3 ] || fail "wait must stop at its round bound, ran $migration_release_rounds"
[ "$sleep_calls" -eq 3 ] || fail 'one sleep per unproductive round'
[ -z "$migration_release_line" ] || fail 'a timeout names no terminal line'

journal_has 'pithead-boot: the stack never became healthy (serving + doctor + status)'
: >"$T/podman"
MIGRATION_RELEASE_WAIT_ROUNDS=240
sleep_calls=0
if migration_release_wait; then fail 'the spent gate must end the wait'; fi
[ "$migration_release_line" = 'pithead-boot: the stack never became healthy (serving + doctor + status)' ] ||
    fail 'the spent-gate line must be the verdict'

printf 'monerod\n' >"$T/podman"
: >"$T/journal"
MIGRATION_RELEASE_WAIT_ROUNDS=2
sleep_calls=0
migration_release_wait && fail 'no release line must fail the wait'
[ "$migration_release_early" = 1 ] || fail 'monerod running before the release line must be flagged early'

journal_has 'pithead-boot: slot committed — chain services released, the data migration runs now'
MIGRATION_RELEASE_WAIT_ROUNDS=240
sleep_calls=0
migration_release_early=9
migration_release_wait || fail 'a released boot with monerod up must pass'
[ "$migration_release_early" = 0 ] || fail 'monerod up after the release is not early'

printf 'booted slot=B\nRAUC_BOOT_PRIMARY=A\n' >"$T/evidence"
out=$(migration_release_deadline_evidence)
case $out in
*'migration release deadline'*) ;;
*) fail 'the deadline dump needs its header' ;;
esac
case $out in
*'booted slot=B'*) ;;
*) fail 'the deadline dump must carry the guest slot state' ;;
esac

echo 'selftest-migration-release-wait: PASS'
