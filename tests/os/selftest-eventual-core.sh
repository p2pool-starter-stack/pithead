#!/usr/bin/env bash
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$HERE/../integration/lib/fake-eventual.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
for name in _control_requests_drained _wait_ssh _wait_new_boot _reboot_wait \
    _dash_marker_served _wait_dhcp_ip _wait_setup_page wait_serial; do
    eval "$(sed -n "/^${name}() {/,/^}/p" "$HERE/lib/core.sh")"
    declare -F "$name" >/dev/null
done
eval "$(sed -n '/^_boot_id() /p' "$HERE/lib/core.sh")"

drive() (
    waiter=$1 mode=$2 clock=0
    printf '0\n' >"$work/reads"
    rm -f "$work/rebooted"
    export SERIAL="$work/serial"
    printf 'waiting\n' >"$SERIAL"
    date() { [ "$*" = +%s ] && printf '%s\n' "$clock"; }
    sleep() {
        clock=$((clock + $1))
        if [ "$waiter" = wait_serial ]; then
            fake_eventual "$work/reads" "$mode" 2 waiting booted >>"$SERIAL" || return 1
        fi
    }
    info() { printf '%s\n' "$1"; }
    _ssh() {
        case "$*" in
        true) [ "$(fake_eventual "$work/reads" "$mode" 2 waiting reachable)" = reachable ] ;;
        'cat /proc/sys/kernel/random/boot_id')
            if [ "$waiter" = _reboot_wait ] && [ ! -f "$work/rebooted" ]; then
                printf 'old-boot\n'
            else
                fake_eventual "$work/reads" "$mode" 2 old-boot new-boot
            fi
            ;;
        reboot) touch "$work/rebooted" ;;
        *'wc -l'*) fake_eventual "$work/reads" "$mode" 2 1 0 ;;
        *) return 2 ;;
        esac
    }
    curl() {
        if [ "$waiter" = _dash_marker_served ]; then
            fake_eventual "$work/reads" "$mode" 2 old-marker new-marker
        else
            fake_eventual "$work/reads" "$mode" 2 warming 'Pithead setup'
        fi
    }
    vm_lease_ip() { fake_eventual "$work/reads" "$mode" 2 '' fixture-address; }
    local rc=0
    export ip=fixture-address
    case "$waiter" in
    _wait_new_boot) "$waiter" old-boot 30 >"$work/output" 2>&1 || rc=$? ;;
    _reboot_wait) "$waiter" reboot 30 >"$work/output" 2>&1 || rc=$? ;;
    _dash_marker_served) "$waiter" new-marker 30 >"$work/output" 2>&1 || rc=$? ;;
    wait_serial) "$waiter" booted 30 >"$work/output" 2>&1 || rc=$? ;;
    *) "$waiter" 30 >"$work/output" 2>&1 || rc=$? ;;
    esac
    if [ "$mode" = never ]; then
        [ "$rc" = 1 ] && [ "$clock" = 30 ] || return 1
        case "$waiter" in
        _wait_new_boot | _reboot_wait) grep -Fq 'boot id old-boot' "$work/output" || return 1 ;;
        _dash_marker_served) grep -Fxq old-marker "$work/output" || return 1 ;;
        _control_requests_drained) grep -Fq '1 in-flight request(s)' "$work/output" || return 1 ;;
        esac
    else
        [ "$rc" = 0 ] && [ "$clock" -gt 0 ] && [ "$clock" -lt 30 ] || return 1
        if [ "$mode" = after ]; then
            [ "$(cat "$work/reads")" = 3 ] || return 1
        else
            [ "$(cat "$work/reads")" = 2 ] || return 1
        fi
    fi
    return 0
)

for waiter in _control_requests_drained _wait_ssh _wait_new_boot _reboot_wait \
    _dash_marker_served _wait_dhcp_ip _wait_setup_page wait_serial; do
    for mode in after never flapping; do
        if drive "$waiter" "$mode"; then
            printf 'PASS: %s %s\n' "$waiter" "$mode"
        else
            printf 'FAIL: %s %s\n' "$waiter" "$mode" >&2
            cat "$work/output" >&2
            exit 1
        fi
    done
done
