#!/usr/bin/env bash
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
work=$(mktemp -d) || exit $?
trap 'command rm -rf "$work"' EXIT

# shellcheck source=os/overlay/pithead-data-reset
source "$ROOT/os/overlay/pithead-data-reset"

TRACE="$work/trace"
MKTEMP_FAIL=""
MARKER_PRESENT=""
MOUNT_RESULT=1
cases=0

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

count() {
    awk -v prefix="$1" 'index($0, prefix) == 1 { n++ } END { print n + 0 }' "$TRACE"
}

reset_fixture() {
    : >"$TRACE"
    command rm -f "$work/esp-mounted"
    MKTEMP_FAIL=""
    MARKER_PRESENT=""
    MOUNT_RESULT=1
}

mktemp() {
    local call dir
    call=$(($(count 'mktemp ') + 1))
    if [ "$MKTEMP_FAIL" = all ] || [ "$MKTEMP_FAIL" = "$call" ]; then
        printf 'mktemp failed\n' >>"$TRACE"
        return 1
    fi
    dir=$(command mktemp -d "$work/mount.XXXXXX") || return $?
    printf 'mktemp %s\n' "$dir" >>"$TRACE"
    printf '%s\n' "$dir"
}

mount() {
    if [ "${1:-}" = -o ] && [ "${2:-}" = ro ]; then
        printf 'mount-ro %s\n' "$3" >>"$TRACE"
        return "$MOUNT_RESULT"
    fi
    printf 'mount %s\n' "$1" >>"$TRACE"
    [ -z "$MARKER_PRESENT" ] || : >"$2/$MARKER_NAME"
    printf '%s\n' "$2" >"$work/esp-mounted"
    return 0
}

umount() {
    printf 'umount %s\n' "$1" >>"$TRACE"
    if [ -f "$work/esp-mounted" ] && [ "$(cat "$work/esp-mounted")" = "$1" ]; then
        command rm -f "$work/esp-mounted"
    fi
    return 0
}

mountpoint() {
    [ "${1:-}" = -q ] || return 2
    [ -f "$work/esp-mounted" ] && [ "$(cat "$work/esp-mounted")" = "$2" ]
}

rmdir() {
    printf 'rmdir %s\n' "$1" >>"$TRACE"
    command rmdir "$@"
}

fsck() {
    printf 'fsck\n' >>"$TRACE"
    return 1
}

e2fsck() {
    printf 'e2fsck %s\n' "$*" >>"$TRACE"
    return 1
}

mke2fs() {
    printf 'mke2fs\n' >>"$TRACE"
    printf 'Superblock backups stored on blocks:\n32768, 98304\n'
}

function mkfs.ext4 {
    printf 'mkfs.ext4\n' >>"$TRACE"
    return 0
}

for failed_probe in 1 2 3 4 5; do
    reset_fixture
    if [ "$failed_probe" -eq 1 ]; then MKTEMP_FAIL=all; else MKTEMP_FAIL=$failed_probe; fi
    output=$(data_reset_decision "$work/data-part" "$work/no-marker")
    rc=$?
    [ "$rc" -eq 2 ] || fail "probe $failed_probe returned decision status $rc with verdict ${output:-<empty>}"
    [ -z "$output" ] || fail "probe $failed_probe emitted destructive verdict: $output"
    [ "$(count 'mount-ro ')" -eq "$((failed_probe - 1))" ] ||
        fail "probe $failed_probe continued mounting after allocation failed"
    expected_fsck=0
    [ "$failed_probe" -ge 2 ] && expected_fsck=1
    [ "$(count 'fsck')" -eq "$expected_fsck" ] ||
        fail "probe $failed_probe ran the wrong number of preen repairs"
    expected_e2fsck=0
    [ "$failed_probe" -ge 3 ] && expected_e2fsck=$((failed_probe - 2))
    [ "$(count 'e2fsck ')" -eq "$expected_e2fsck" ] ||
        fail "probe $failed_probe continued full repair after allocation failed"
    expected_geometry=0
    [ "$failed_probe" -ge 4 ] && expected_geometry=1
    [ "$(count 'mke2fs')" -eq "$expected_geometry" ] ||
        fail "probe $failed_probe continued to backup-superblock discovery"
    [ "$(count 'mkfs.ext4')" -eq 0 ] || fail "probe $failed_probe formatted data"
    cases=$((cases + 1))
done

reset_fixture
MKTEMP_FAIL=1
try_mount_ro "$work/data-part"
rc=$?
[ "$rc" -eq 2 ] || fail "try_mount_ro returned $rc when probe allocation failed"
[ "$(count 'mount-ro ')" -eq 0 ] || fail 'allocation failure attempted a mount'
cases=$((cases + 1))

reset_fixture
try_mount_ro "$work/data-part"
rc=$?
[ "$rc" -eq 1 ] || fail "try_mount_ro returned $rc when the mount failed"
[ "$(count 'mount-ro ')" -eq 1 ] || fail 'failed mount was not attempted exactly once'
cases=$((cases + 1))

reset_fixture
MOUNT_RESULT=0
try_mount_ro "$work/data-part"
rc=$?
[ "$rc" -eq 0 ] || fail "try_mount_ro returned $rc for a healthy filesystem"
[ "$(count 'mount-ro ')" -eq 1 ] || fail 'healthy probe did not mount exactly once'
[ "$(count 'umount ')" -eq 1 ] || fail 'healthy probe was not unmounted'
cases=$((cases + 1))

reset_fixture
MOUNT_RESULT=0
output=$(data_reset_decision "$work/data-part" "$work/no-marker")
rc=$?
[ "$rc" -eq 0 ] || fail "healthy decision returned status $rc"
[ "$output" = skip ] || fail "healthy decision returned $output"
[ "$(count 'mount-ro ')" -eq 1 ] || fail 'healthy decision did not perform the real probe'
[ "$(count 'fsck')" -eq 0 ] || fail 'healthy decision attempted repair'
[ "$(count 'mkfs.ext4')" -eq 0 ] || fail 'healthy decision formatted data'
cases=$((cases + 1))

reset_fixture
MKTEMP_FAIL=1
reformat_data "$work/data-part"
rc=$?
[ "$rc" -ne 0 ] || fail 'reformat_data accepted unavailable mount space'
[ "$(count 'mkfs.ext4')" -eq 0 ] || fail 'reformat_data formatted before allocating mount space'
[ "$(count 'mount')" -eq 0 ] || fail 'reformat_data attempted a mount without mount space'
cases=$((cases + 1))

boot_disk_part() {
    case "$1" in
    data) printf '%s\n' "$work/data-part" ;;
    esp) printf '%s\n' "$work/esp-part" ;;
    *) return 1 ;;
    esac
}

function [ {
    if builtin [ "${1:-}" = -b ]; then
        return 0
    fi
    builtin [ "$@"
}

reset_fixture
MKTEMP_FAIL=2
main >"$work/main-output" 2>"$work/main-error"
rc=$?
[ "$rc" -ne 0 ] || fail 'main accepted unavailable probe space'
[ ! -s "$work/main-output" ] || fail 'main emitted a reset verdict on stdout'
[ -s "$work/main-error" ] || fail 'main did not diagnose unavailable probe space'
[ "$(count 'fsck')" -eq 0 ] || fail 'main repaired data after its first probe allocation failed'
[ "$(count 'mkfs.ext4')" -eq 0 ] || fail 'main formatted data after probe allocation failed'
[ "$(count 'umount ')" -eq 1 ] || fail 'main did not unmount the ESP after refusal'
esp_mnt=$(awk '$1 == "mktemp" { print $2; exit }' "$TRACE")
[ -n "$esp_mnt" ] && [ ! -e "$esp_mnt" ] || fail 'main did not remove the ESP mount directory'
cases=$((cases + 1))

reset_fixture
MKTEMP_FAIL=all
main >"$work/main-output" 2>"$work/main-error"
rc=$?
[ "$rc" -ne 0 ] || fail 'main accepted unavailable ESP mount space'
[ ! -s "$work/main-output" ] || fail 'ESP allocation failure emitted a reset verdict'
[ -s "$work/main-error" ] || fail 'ESP allocation failure had no diagnostic'
[ "$(count 'mount')" -eq 0 ] || fail 'ESP allocation failure attempted a mount'
[ "$(count 'fsck')" -eq 0 ] || fail 'ESP allocation failure attempted repair'
[ "$(count 'mkfs.ext4')" -eq 0 ] || fail 'ESP allocation failure formatted data'
cases=$((cases + 1))

reset_fixture
MKTEMP_FAIL=2
MARKER_PRESENT=1
main >"$work/main-output" 2>"$work/main-error"
rc=$?
[ "$rc" -ne 0 ] || fail 'main accepted unavailable reformat mount space'
[ "$(count 'mkfs.ext4')" -eq 0 ] || fail 'requested reset formatted without mount space'
esp_mnt=$(awk '$1 == "mktemp" { print $2; exit }' "$TRACE")
[ -f "$esp_mnt/$MARKER_NAME" ] || fail 'refused reset consumed the reset marker'
cases=$((cases + 1))

printf 'selftest-data-reset-probe: %s cases passed\n' "$cases"
