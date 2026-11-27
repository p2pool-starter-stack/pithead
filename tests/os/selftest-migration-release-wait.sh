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

journalctl() {
    local boot=current
    while [ $# -gt 0 ]; do
        if [ "$1" = '-b' ]; then
            case "${2:-}" in
            '-1') boot=prev ;;
            esac
        fi
        shift
    done
    case $boot in
    prev) cat "$T/journal_prev" 2>/dev/null ;;
    *) cat "$T/journal" 2>/dev/null ;;
    esac
    return 0
}
podman() {
    cat "$T/podman" 2>/dev/null
    return 0
}
_ssh() {
    case "$1" in
    *'-- slots --'*)
        [ "${SSH_TIMEOUT:-}" = 60 ] || printf 'deadline dump without SSH_TIMEOUT=60\n' >"$T/violation"
        cat "$T/evidence"
        ;;
    *)
        [ "${SSH_TIMEOUT:-}" = 20 ] || printf 'release-wait poll without SSH_TIMEOUT=20: %s\n' "$1" >"$T/violation"
        eval "$1"
        ;;
    esac
}
journal_has() {
    printf '%s\n' "$1" >"$T/journal"
    : >"$T/journal_prev"
}
journal_prev_has() { printf '%s\n' "$1" >"$T/journal_prev"; }
podman_running() { printf 'monerod\n' >"$T/podman"; }
podman_quiet() { : >"$T/podman"; }

journal_has 'pithead-boot: slot committed — chain services released, the data migration runs now'
podman_quiet
MIGRATION_RELEASE_WAIT_ROUNDS=240
sleep_calls=0
migration_release_early=9
migration_release_wait || fail 'the release line must end the wait green'
[ "$migration_release_rounds" -eq 1 ] || fail 'the release check must run first in a round'
[ "$migration_release_early" = 0 ] || fail 'monerod beside a released boot is not early'
[ "$sleep_calls" -eq 0 ] || fail 'a released boot must not sleep a round'

journal_has 'pithead-boot: the stack could not be brought up — slot left uncommitted so A/B fallback stays armed'
podman_running
MIGRATION_RELEASE_WAIT_ROUNDS=240
sleep_calls=0
if migration_release_wait; then fail 'a dead boot must not report release'; fi
[ "$migration_release_line" = 'pithead-boot: the stack could not be brought up — slot left uncommitted so A/B fallback stays armed' ] ||
    fail "the terminal verdict lost the boot's line: $migration_release_line"
[ "$sleep_calls" -eq 0 ] || fail 'a dead boot must end the wait without another round'

journal_has ''
podman_quiet
MIGRATION_RELEASE_WAIT_ROUNDS=3
sleep_calls=0
if migration_release_wait; then fail 'a boot that logs nothing must fail at the bound'; fi
[ "$migration_release_rounds" -eq 3 ] || fail "wait must stop at its round bound, ran $migration_release_rounds"
[ "$sleep_calls" -eq 3 ] || fail 'one sleep per unproductive round'
[ -z "$migration_release_line" ] || fail 'a timeout names no terminal line'

journal_has 'pithead-boot: the stack never became healthy (serving + doctor + status)'
podman_quiet
MIGRATION_RELEASE_WAIT_ROUNDS=240
sleep_calls=0
if migration_release_wait; then fail 'the spent gate must end the wait'; fi
[ "$migration_release_line" = 'pithead-boot: the stack never became healthy (serving + doctor + status)' ] ||
    fail 'the spent-gate line must be the verdict'

journal_has ''
podman_running
MIGRATION_RELEASE_WAIT_ROUNDS=2
sleep_calls=0
migration_release_wait && fail 'no release line must fail the wait'
[ "$migration_release_early" = 1 ] || fail 'monerod running before the release line must be flagged early'

journal_has 'pithead-boot: slot committed — chain services released, the data migration runs now'
podman_running
MIGRATION_RELEASE_WAIT_ROUNDS=240
sleep_calls=0
migration_release_early=9
migration_release_wait || fail 'a released boot with monerod up must pass'
[ "$migration_release_early" = 0 ] || fail 'monerod up after the release is not early'

journal_has ''
journal_prev_has 'pithead-boot: the stack could not be brought up — slot left uncommitted so A/B fallback stays armed'
podman_running
MIGRATION_RELEASE_WAIT_ROUNDS=240
sleep_calls=0
if migration_release_wait; then fail 'a fallback reboot must not report release'; fi
[ "$migration_release_line" = 'pithead-boot: the stack could not be brought up — slot left uncommitted so A/B fallback stays armed' ] ||
    fail 'the wait must name the candidate line from the previous boot after an automatic fallback'
[ "$sleep_calls" -eq 0 ] || fail 'a terminal previous-boot line must end the wait in one round'

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

(
    unset MIGRATION_RELEASE_WAIT_ROUNDS
    # shellcheck source=tests/os/migration-recovery.sh
    source "$HERE/migration-recovery.sh"
    [ "${MIGRATION_RELEASE_WAIT_ROUNDS:-0}" -eq 240 ]
) || fail 'the release wait default must stay 240 rounds (#3957)'

overlay="$HERE/../../os/overlay/pithead-boot"
for needle in 'slot left uncommitted' 'never became healthy' 'this is failure' 'NOT a bad slot' 'migration marker could not be assigned'; do
    grep -qF -- "$needle" "$overlay" || fail "pithead-boot no longer emits [$needle] — the terminal pattern is stale"
    case $MIGRATION_RELEASE_TERMINAL in
    *"$needle"*) ;;
    *) fail "the terminal pattern list dropped [$needle]" ;;
    esac
done

[ ! -e "$T/violation" ] || fail "$(<"$T/violation")"

echo 'selftest-migration-release-wait: PASS'
