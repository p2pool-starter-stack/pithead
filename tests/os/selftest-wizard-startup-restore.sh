#!/usr/bin/env bash
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$HERE/../integration/lib/reset-restore-startup.sh"
work=$(mktemp -d "${TMPDIR:-/tmp}/wizard-startup-restore-selftest.XXXXXX")
trap 'rm -rf "$work"' EXIT
run_case() (
    fault="$1"
    OUT_DIR="$work/$fault"
    mkdir "$OUT_DIR"
    export IT_PITHEAD=./pithead
    passes=0 failures=0
    it_pass() { passes=$((passes + 1)); }
    it_fail() { failures=$((failures + 1)); }
    quote_arg() { printf "'%s'" "$1"; }
    redact() { cat; }
    reset_restore_wait_reboot() { [ "$fault" != reboot ]; }
    wait_for() {
        shift 3
        "$@"
    }
    rx() {
        case "$1" in
        'cat /proc/sys/kernel/random/boot_id') printf 'before\n' ;;
        *config-reset*) printf 'Rebooting into first-boot\n' ;;
        *'docker rm -f pithead-wizard'*) [ "$fault" != stop ] ;;
        *'cat > .wizard-startup-probe.sh')
            [ "${2:-}" = --stdin ] || return 1
            cat >"$OUT_DIR/probe"
            cmp -s "$OUT_DIR/probe" "$RR_STARTUP_GUEST"
            ;;
        *'systemctl start --no-block'*)
            [ "$fault" = held ] || touch "$OUT_DIR/held"
            ;;
        'test -e .wizard-startup-held && test ! -e config.json')
            [ -f "$OUT_DIR/held" ] && [ ! -e "$OUT_DIR/config" ]
            ;;
        *' restore -y '*)
            [ "$fault" != restore ] || return 1
            touch "$OUT_DIR/config"
            ;;
        'test -s config.json && touch .wizard-startup-release')
            [ -e "$OUT_DIR/config" ] && touch "$OUT_DIR/released"
            ;;
        'systemctl show pithead-firstboot.service -p ActiveState -p Result -p ExecMainStatus')
            [ -e "$OUT_DIR/released" ] || return 1
            case "$fault" in
            active) printf 'ActiveState=activating\nResult=success\nExecMainStatus=0\n' ;;
            exit) printf 'ActiveState=inactive\nResult=exit-code\nExecMainStatus=1\n' ;;
            *) printf 'ActiveState=inactive\nResult=success\nExecMainStatus=0\n' ;;
            esac
            ;;
        "ss -H -ltn 'sport = :80 or sport = :443'")
            [ "$fault" != census ] || return 1
            [ "$fault" != ports ] || printf 'LISTEN\n'
            ;;
        *'touch .wizard-startup-release'*'systemctl stop'*)
            touch "$OUT_DIR/cleanup"
            [ "$fault" != cleanup ]
            ;;
        *'journalctl -b -u pithead-firstboot.service'*) : ;;
        *)
            printf 'unexpected transport: %s\n' "$*" >&2
            return 99
            ;;
        esac
    }
    rr_wizard_absent() { [ "$fault" != wizard ]; }
    pithead() {
        [ -e "$OUT_DIR/released" ] && [ "$fault" != up ] && touch "$OUT_DIR/up"
    }
    rr_web_ports_owned_by_dashboard() {
        [ -e "$OUT_DIR/up" ] && [ "$fault" != dashboard ]
    }
    wait_status_ok() { [ "$fault" != health ]; }
    rc=0
    rr_restore_during_wizard_startup fixture.enc || rc=$?
    [ -e "$OUT_DIR/cleanup" ]
    if [ "$fault" = none ]; then
        [ "$rc" = 0 ] && [ "$failures" = 0 ] && [ "$passes" = 5 ]
    else
        [ "$rc" != 0 ]
    fi
)
for fault in none reboot stop held restore active exit wizard census ports up dashboard health cleanup; do
    if run_case "$fault"; then
        printf 'PASS: startup restore proof %s\n' "$fault"
    else
        printf 'FAIL: startup restore proof %s\n' "$fault" >&2
        exit 1
    fi
done
