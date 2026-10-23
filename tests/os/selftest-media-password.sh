#!/usr/bin/env bash
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
OS_RUN_SUITE=1 SCRIPT_DIR="$HERE" DISK="$work/disk.img" SERIAL="$work/serial" ip=fixture
# shellcheck source=tests/os/phases/media.sh
source "$HERE/phases/media.sh"
sleep() { :; }
date() {
    local n
    n=$(cat "$work/time")
    printf '%s' "$n"
    printf '%s' "$((n + 500))" >"$work/time"
}
ok() { :; }
bad() { printf 'expected refusal: %s\n' "$*"; }
_make_media_stick() { printf '%s' "$2" >"$1"; }
_attach_media_stick() { return 0; }
_detach_media_stick() { [ "$mode" != detach-error ]; }
_reboot_wait() { [ "$mode" != reboot-error ]; }
_wait_ssh() { return 0; }
wait_serial() { [ "$mode" != not-applied ]; }
serial_has() {
    if [ "$1" = dashboard.auth.password ]; then
        [ "$mode" != no-path ]
    else [ "$mode" = secret-leak ]; fi
}
dashboard_curl() {
    if [ "$DASH_PASS" = old ]; then
        if [ "$mode" = old-accepted ]; then printf 200; else printf 401; fi
    elif [ "$mode" = new-refused ]; then printf 401; else printf 200; fi
}
_media_stick_has_config() {
    case "$mode" in retained) return 0 ;; read-error) return 2 ;; *) return 1 ;; esac
}
for mode in ready old-accepted new-refused retained read-error secret-leak no-path not-applied reboot-error detach-error; do
    printf 0 >"$work/time"
    if [ "$mode" = ready ]; then
        media_password_recovery user old
    else ! media_password_recovery user old || exit 1; fi
done

(
    # shellcheck source=tests/os/phases/media.sh
    source "$HERE/phases/media.sh"
    DISK="$work/probe.img"
    loop_fixture="$work/loop"
    touch "${loop_fixture}p1"
    losetup() {
        [ "$mode" != loop-error ] || return 1
        [[ "$*" = *--show* ]] && printf '%s' "$loop_fixture"
        return 0
    }
    mount() {
        [ "$mode" != mount-error ] || return 1
        [ "$mode" != present ] || touch "${!#}/pithead-config.json"
    }
    umount() { rm -f "$1/pithead-config.json"; }
    for mode in present absent mount-error loop-error; do
        rc=0
        _media_stick_has_config "$DISK" || rc=$?
        case "$mode:$rc" in present:0 | absent:1 | mount-error:2 | loop-error:2) : ;; *) exit 1 ;; esac
    done
)
printf 'PASS: USB password transition, console redaction, consumption and unreadable-media controls\n'
