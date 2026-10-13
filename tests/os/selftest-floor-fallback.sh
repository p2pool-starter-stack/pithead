#!/usr/bin/env bash
# The fallback wait must accept either previous-slot layout, after observing a reboot,
# while rejecting the failing slot and a previous slot whose gate has not committed.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
# shellcheck source=tests/os/data-floor-fallback-leg.sh
SCRIPT_DIR="$HERE" source "$HERE/data-floor-fallback-leg.sh"

fail() {
    echo "FAIL: $1"
    exit 1
}
date() { cat "$T/clock"; }
sleep() { echo "$(($(cat "$T/clock") + $1))" >"$T/clock"; }
_reboot_wait() {
    [ "$1" = reboot ] && [ "$2" = 60 ] || fail "reboot arguments"
    echo reboot >>"$T/events"
    return "$REBOOT_RC"
}
_ssh() {
    [ -s "$T/events" ] || fail "polled before observing reboot"
    case "$*" in
    *'cat /etc/pithead-test-marker'*'journalctl -u pithead-boot -b '*) ;;
    *) fail "probe must read the marker and current boot's journal" ;;
    esac
    echo probe >>"$T/events"
    local n
    n=$(wc -l <"$T/events")
    if [ "$n" -eq 2 ]; then
        printf '%s\n' "$FIRST"
    else
        printf '%s\n' "$LATER"
    fi
}
check_wait() {
    local label="$1" want="$2" rc=0
    FIRST="$3" LATER="$4" REBOOT_RC="$5"
    echo 0 >"$T/clock"
    : >"$T/events"
    _floor_fallback_wait vfail 60 || rc=$?
    [ "$rc" -eq "$want" ] || fail "$label: rc=$rc, want $want"
}

check_wait 'v1 fallback' 0 $'vfail\n0' $'v1\n1' 0
check_wait 'vmig fallback' 0 $'vfail\n0' $'vmig\n1' 0
check_wait 'failing slot never leaves' 1 $'vfail\n0' $'vfail\n0' 0
check_wait 'failing slot commits' 1 $'vfail\n1' $'vfail\n1' 0
check_wait 'previous slot never commits' 1 $'v1\n0' $'v1\n0' 0
check_wait 'wait for fallback commit' 0 $'v1\n0' $'v1\n1' 0
check_wait 'missing marker' 1 $'\n1' $'\n1' 0
check_wait 'unreadable journal' 1 'v1' 'v1' 0
check_wait 'old boot still committed' 1 $'v1\n1' $'v1\n1' 1
[ "$(cat "$T/events")" = reboot ] || fail 'polled despite unobserved reboot'
printf 'selftest-floor-fallback: ok\n'
