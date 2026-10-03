#!/usr/bin/env bash
# Regression for #3049: the floor-fallback leg separates bundle staging from os-update. A failed
# staging must report an environment/transport fault with its scp stderr and never invoke
# os-update; a successful staging must still run os-update.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
SERIAL="$T/serial" KEY="$T/key" ip=192.0.2.1 VM=selftest PASS=0 FAIL=0 KEEP=1 OS_RUN_SUITE=1
# shellcheck source=tests/os/lib/core.sh
source "$HERE/lib/core.sh"
# shellcheck source=tests/os/staging-failure-evidence.sh
source "$HERE/staging-failure-evidence.sh"
# shellcheck source=tests/os/data-floor-fallback-leg.sh
SCRIPT_DIR="$HERE" source "$HERE/data-floor-fallback-leg.sh"
trap 'rm -rf "$T"' EXIT
SERIAL="$T/serial"
printf 'console line\n' >"$SERIAL"
printf 'bundle' >"$T/bundle"

OSUPDATE_CALLS=0
_ssh() {
    case "$*" in *os-update*) OSUPDATE_CALLS=$((OSUPDATE_CALLS + 1)) ;; esac
    echo "probe-output"
}
mkdir "$T/bin"
printf '#!/bin/sh\necho running\n' >"$T/bin/virsh"
chmod +x "$T/bin/virsh"
PATH="$T/bin:$PATH"
fail() {
    echo "FAIL: $1"
    exit 1
}

# The staging bound is real: a hung scp is killed at STAGE_TIMEOUT with rc 124.
printf '#!/bin/sh\nsleep 30\n' >"$T/bin/scp"
chmod +x "$T/bin/scp"
# shellcheck disable=SC2218 # the real one from core.sh; the stub below replaces it afterwards
STAGE_TIMEOUT=1 _stage_bundle "$T/bundle"
rc=$?
[ "$rc" -eq 124 ] || fail "hung scp not bounded (rc $rc)"

# Default callers (no STAGE_ERR) keep scp's stderr on the console, and the floor leg's local
# STAGE_ERR does not leak out of _floor_stage.
printf '#!/bin/sh\necho "scp: Connection closed" >&2\nexit 255\n' >"$T/bin/scp"
con=$(_stage_bundle "$T/bundle" 2>&1 >/dev/null)
printf '%s' "$con" | grep -qF 'scp: Connection closed' || fail "default staging swallowed scp stderr"
[ -z "${STAGE_ERR:-}" ] || fail "STAGE_ERR leaked as a global"

# Failed staging: scp stderr and rc retained, os-update never invoked.
_stage_bundle() {
    echo 'scp: Connection closed' >>"$STAGE_ERR"
    return 255
}
out=$(_floor_stage "$T/bundle")
rc=$?
[ "$rc" -ne 0 ] || fail "failed staging returned success"
[ "$OSUPDATE_CALLS" -eq 0 ] || fail "os-update invoked on failed staging"
for want in 'rc=255' 'environment/transport fault' 'os-update was NOT invoked' 'scp: Connection closed' 'domain state: running' 'console line' 'probe-output'; do
    printf '%s' "$out" | grep -qF -- "$want" || fail "evidence lacks: $want"
done
[ -f "$SERIAL.failed" ] || fail "serial not retained"

# Successful staging still reaches os-update.
_stage_bundle() { return 0; }
_floor_stage "$T/bundle" || fail "successful staging reported failure"
_floor_os_update >/dev/null
[ "$OSUPDATE_CALLS" -eq 1 ] || fail "os-update not invoked after good staging"

# Phase level: a staging failure at each of the leg's four staging points yields exactly one
# staging row, no os-update-refusal row, and no os-update call at that point.
ok() { :; }
info() { :; }
bad() { ROWS+=("$1"); }
_build_bundle_stamped() { printf '%s' "$T/bundle"; }
bundle_build_evidence() { :; }
osupdate_failure_evidence() { :; }
_floor_fallback_wait() { return 0; }
_floor_state() {
    local seq=("99.0.0|1.0.0|99.0.0" "1.0.0||" "99.0.0|1.0.0|99.0.0" "99.0.0||")
    echo x >>"$T/state-calls"
    printf '%s' "${seq[($(wc -l <"$T/state-calls") - 1) % 4]}"
}
_ssh() {
    case "$*" in
    *os-update*)
        echo x >>"$T/osupdate-calls"
        echo "a migrating update to 99.0.0 failed its gate and fell back before its migration ran"
        [ "$(wc -l <"$T/osupdate-calls")" -ne 4 ] || return 1
        ;;
    *.os-data-floor*) echo 1.0.0 ;;
    *"floor is back to'"*) return 1 ;;
    esac
    return 0
}
for n in 1 2 3 4; do
    ROWS=() STAGE_CALLS=0
    : >"$T/state-calls"
    : >"$T/osupdate-calls"
    _stage_bundle() {
        STAGE_CALLS=$((STAGE_CALLS + 1))
        [ "$STAGE_CALLS" -ne "$n" ]
    }
    phase_provision_floor_fallback_leg "$T/bundle" >/dev/null
    calls=$(wc -l <"$T/osupdate-calls")
    [ "$calls" -eq $((n - 1)) ] || fail "stage failure $n: os-update calls $calls"
    [ "${#ROWS[@]}" -eq 1 ] || fail "stage failure $n: ${#ROWS[@]} failure rows: ${ROWS[*]}"
    case "${ROWS[0]}" in *'bundle staging failed'*) ;; *) fail "stage failure $n: wrong row: ${ROWS[0]}" ;; esac
done
printf 'selftest-floor-staging: ok\n'
