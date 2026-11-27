#!/usr/bin/env bash
# Exercise the real reset readiness gate against asynchronous provisioning I/O.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
OS_RUN_SUITE=1
# shellcheck source=tests/os/provisioning-settled.sh
. "$HERE/provisioning-settled.sh"
# shellcheck source=tests/os/phases/reset-slot.sh
. "${RESET_SLOT_SOURCE:-$HERE/phases/reset-slot.sh}"
fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}
date() { cat "$scratch/clock"; }
sleep() {
    printf '%s\n' "$(($(cat "$scratch/clock") + $1))" >"$scratch/clock"
    SECONDS=$((SECONDS + 300))
}
_ssh() {
    [ "${SSH_TIMEOUT:-}" = 20 ] || fail 'readiness probe has no bounded SSH timeout'
    if [[ "$1" == *'systemctl show'* ]]; then
        if [ "$fixture" = stalled ] || { [ "$fixture" = delayed ] && [ "$(cat "$scratch/clock")" -lt 30 ]; }; then
            printf 'activating\ninactive\nyes\nno\n'
        elif [ "$fixture" = failed ]; then
            printf 'failed\ninactive\nyes\nno\n'
        else
            printf 'inactive\ninactive\nyes\nno\n'
        fi
    else
        printf '%s\n' "$(cat "$scratch/clock")" >>"$scratch/health"
        # Old healthy containers must not permit a reboot before setup finishes.
        if [[ "$1" != *'test -s .env'* ]] || [[ "$1" != *'./pithead status'* ]]; then
            printf '{"summary":{"fail":0}}'
            return 0
        fi
        [ "$fixture" != missing-env ] && [ "$fixture" != unhealthy ] || return 1
        printf '{"summary":{"fail":0}}'
    fi
}
for fixture in delayed stalled failed missing-env unhealthy; do
    printf '0\n' >"$scratch/clock"
    : >"$scratch/health"
    SECONDS=0
    if _reset_slot_good_stack; then
        [ "$fixture" = delayed ] || fail "$fixture accepted as ready"
        [ "$(head -1 "$scratch/health")" -ge 30 ] || fail 'health was accepted before provisioning settled'
    else
        [ "$fixture" != delayed ] || fail 'completed healthy provisioning was refused'
    fi
    if [ "$fixture" = stalled ] || [ "$fixture" = failed ]; then
        [ ! -s "$scratch/health" ] || fail "$fixture reached the health probe"
    fi
done
printf 'selftest-reset-slot-readiness: 5 cases passed\n'
