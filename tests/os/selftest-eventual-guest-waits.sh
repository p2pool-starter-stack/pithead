#!/usr/bin/env bash
set -euo pipefail
echo "== appliance guest eventual waits =="
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$HERE/../integration/lib/selftest/fake-eventual.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
extract() {
    eval "$(sed -n "/^${1}() {/,/^}/p" "$HERE/$2")"
    declare -F "$1" >/dev/null
}
extract _xvb_wait_for_proxy_api appliance-xvb-routing-leg.sh
extract _xvb_wait_for_tor appliance-xvb-routing-leg.sh
extract _xvb_wait_for_gate_release appliance-xvb-gate-wait.sh
extract wait_for_p2pool_held_by_sync_gate appliance-tari-mode-leg.sh
extract wizard_state_poll provision-browser-submit.sh
extract migration_wait_for_mining migration-recovery.sh
extract _reset_slot_wait phases/reset-slot.sh
extract wait_unit_condition_evaluated provisioning-settled.sh
export SCRIPT_DIR=$HERE
sha=0123456789abcdef
ready_snapshot="B|marker|$sha"$'\nA_OK=1\nA_TRY=0\nORDER=B A\nB_TRY=0\n{"booted":"B","boot_primary":"rootfs.1","slots":[{"rootfs.1":{"boot_status":"good"}}]}'

drive() (
    waiter=$1 mode=$2 clock=0 rc=0
    SECONDS=0
    printf '0\n' >"$work/reads"
    printf '0\n' >"$work/runs"
    export XVB_PROXY_READY_TIMEOUT=30 XVB_TOR_READY_TIMEOUT=30 XVB_GATE_RELEASE_TIMEOUT=30
    date() { [ "$*" = +%s ] && printf '%s\n' "$clock"; }
    sleep() {
        clock=$((clock + $1))
        SECONDS=$((SECONDS + $1))
        [ "$clock" -le 5000 ] || exit 99
    }
    _xvb_proxy_ready_payload() { printf 'payload\n'; }
    _xvb_gate_payload() { printf 'payload\n'; }
    _xvb_guest_python() {
        if [ "$waiter" = _xvb_wait_for_gate_release ]; then
            fake_eventual "$work/reads" "$mode" 2 held released
        else
            [ "$(fake_eventual "$work/reads" "$mode" 2 no yes)" = yes ]
        fi
    }
    _ssh() { fake_eventual "$work/runs" "$mode" 2 starting healthy; }
    p2pool_held_by_sync_gate() { [ "$(fake_eventual "$work/reads" "$mode" 2 no yes)" = yes ]; }
    curl() {
        fake_eventual "$work/reads" "$mode" 2 '' '{"state":"ready"}'
        printf '\n200'
    }
    git() { printf '%s\n' "$sha"; }
    migration_services_healthy() { true; }
    _reset_slot_snapshot() { fake_eventual "$work/reads" "$mode" 2 'A|marker|none' "$ready_snapshot"; }
    if [ "$waiter" = _xvb_wait_for_gate_release ]; then
        _ssh() { fake_eventual "$work/runs" "$mode" 2 false true; }
    fi
    case "$waiter" in
    migration_wait_for_mining)
        _ssh() { fake_eventual "$work/reads" "$mode" 2 '' "ready 1 $(($(cat "$work/reads") * 10))"; }
        ;;
    wait_unit_condition_evaluated)
        export UNIT_CONDITION_ATTEMPTS=10
        _ssh() { fake_eventual "$work/reads" "$mode" 2 0 123; }
        ;;
    esac
    case "$waiter" in
    wait_unit_condition_evaluated) "$waiter" fixture.service >"$work/output" 2>&1 || rc=$? ;;
    migration_wait_for_mining) "$waiter" 0 >"$work/output" 2>&1 || rc=$? ;;
    _reset_slot_wait) "$waiter" B marker no 30 >"$work/output" 2>&1 || rc=$? ;;
    wizard_state_poll) "$waiter" fixture-address fixture-jar .state >"$work/output" 2>&1 || rc=$? ;;
    *) "$waiter" >"$work/output" 2>&1 || rc=$? ;;
    esac
    if [ "$mode" = never ]; then
        [ "$rc" = 1 ] || return 1
        case "$waiter" in
        _xvb_wait_for_proxy_api | _xvb_wait_for_tor | _xvb_wait_for_gate_release) [ "$clock" -ge 30 ] || return 1 ;;
        wait_for_p2pool_held_by_sync_gate) [ "$clock" = 120 ] || return 1 ;;
        wizard_state_poll) [ "$clock" = 30 ] || return 1 ;;
        migration_wait_for_mining) [ "$clock" -ge 1800 ] || return 1 ;;
        _reset_slot_wait) [ "$clock" -ge 30 ] || return 1 ;;
        wait_unit_condition_evaluated) [ "$clock" = 10 ] || return 1 ;;
        esac
        case "$waiter" in
        _xvb_wait_for_tor) grep -Fxq starting "$work/output" || return 1 ;;
        _xvb_wait_for_gate_release) grep -Fxq 'gate=held proxy-running=false' "$work/output" || return 1 ;;
        wizard_state_poll) printf '%s\n' "$WIZ_STATE_WHY" >"$work/output" && grep -Fq 'after 6x5s' "$work/output" || return 1 ;;
        esac
    else
        [ "$rc" = 0 ] && [ "$clock" -gt 0 ] && [ "$clock" -lt 30 ] || return 1
    fi
)

for waiter in _xvb_wait_for_proxy_api _xvb_wait_for_tor _xvb_wait_for_gate_release \
    wait_for_p2pool_held_by_sync_gate wizard_state_poll migration_wait_for_mining _reset_slot_wait \
    wait_unit_condition_evaluated; do
    for mode in after never; do
        if drive "$waiter" "$mode"; then
            printf 'PASS: %s %s\n' "$waiter" "$mode"
        else
            printf 'FAIL: %s %s\n' "$waiter" "$mode" >&2
            cat "$work/output" >&2
            exit 1
        fi
    done
done
