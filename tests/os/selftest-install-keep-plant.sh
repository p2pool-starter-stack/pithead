#!/usr/bin/env bash
# Exercise the streamed guest script and its real harness caller with command doubles.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
work=$(mktemp -d)
export TMPDIR="$work"
trap 'if [ -f "$work/stderr-path" ]; then command rm -f "$(cat "$work/stderr-path")"; fi; command rm -rf "$work"' EXIT
trap 'printf "Keep-plant selftest failed at line %s (case %s)\n" "$LINENO" "${PLANT_FAIL:-success}" >&2' ERR
export PLANT_WORK="$work" PLANT_TRACE="$work/trace" PLANT_FAIL='' PLANT_CLEANUP_FAIL=''

record() { printf '%s\n' "$1" >>"$PLANT_TRACE"; }
refuse() {
    if [ "$PLANT_FAIL" = "$1" ] || [ "$PLANT_CLEANUP_FAIL" = "$1" ]; then
        printf 'fixture stderr for %s\n' "$1" >&2
        return 17
    fi
}
mktemp() {
    record mountpoint
    refuse mountpoint || return $?
    printf '%s\n' "$PLANT_WORK/target"
}
mount() {
    record mount
    refuse mount || return $?
    [ "$1" = /dev/vda4 ] && [ "$2" = "$PLANT_WORK/target" ]
}
mkdir() {
    record directories
    refuse directories || return $?
    command mkdir "$@"
}
podman() {
    case "$3" in
    load)
        record load
        if [ "$PLANT_FAIL" = noisy-load ]; then
            for i in {1..100}; do printf '\033[31merror line %s %0500d\033[0m\n' "$i" 0 >&2; done
            return 17
        fi
        refuse load || return $?
        [ "$*" = "--root $PLANT_WORK/target/containers/storage load -qi /opt/pithead/images/dashboard.tar.gz" ]
        ;;
    images)
        record image-lookup
        refuse image-lookup || return $?
        case "$PLANT_FAIL" in
        empty-image) printf 'unrelated 123456abcdef\n' ;;
        malformed-image) printf 'pithead-dashboard invalid-id\n' ;;
        *) printf 'pithead-dashboard 123456abcdef\n' ;;
        esac
        ;;
    *) return 99 ;;
    esac
}
sha256sum() {
    record digest
    refuse digest || return $?
    printf '%064d  archive\n' 0
}
rm() {
    record database-cleanup
    refuse database-cleanup || return $?
    [ "$*" = "-rf $PLANT_WORK/target/containers/storage/db.sql $PLANT_WORK/target/containers/storage/libpod" ]
}
umount() {
    record unmount
    refuse unmount || return $?
    [ "$1" = "$PLANT_WORK/target" ]
}
export -f record refuse mktemp mount mkdir podman sha256sum rm umount

# Load the real wrapper, not a second implementation of its status/diagnostic handling.
# shellcheck disable=SC2034 # dynamically consumed by the sourced harness helper.
OS_RUN_SUITE=1 SCRIPT_DIR="$HERE"
# shellcheck source=tests/os/phases/install-reinstall.sh
source "$HERE/phases/install-reinstall.sh"
_ssh() {
    printf '%s\n' "$SSH_ERR" >"$work/stderr-path"
    bash -s 2>"$SSH_ERR"
}
run() {
    if [ -f "$work/stderr-path" ]; then command rm -f "$(cat "$work/stderr-path")"; fi
    : >"$PLANT_TRACE"
    rc=0
    _phase_install_keep_plant >"$work/out" 2>"$work/err" || rc=$?
    if [ -f "$work/stderr-path" ]; then saved_stderr=$(cat "$work/stderr-path"); fi
}
run
[ "$rc" -eq 0 ] && [ "$(cat "$work/out")" = 123456abcdef ] && [ ! -s "$work/err" ] && [ ! -e "$saved_stderr" ]
[ "$(cat "$PLANT_TRACE")" = $'mountpoint\nmount\ndirectories\nload\ndigest\nimage-lookup\ndatabase-cleanup\nunmount' ]
[ "$(cat "$work/target/pithead/data/.loaded-dashboard.tar.gz.sha")" = "$(printf '%064d' 0)" ]

for PLANT_FAIL in mountpoint mount directories load digest image-lookup database-cleanup unmount; do
    export PLANT_FAIL
    run
    [ "$rc" -eq 17 ] && [ ! -s "$work/out" ]
    grep -q "sub-step=$PLANT_FAIL failed exit=17" "$work/err"
    grep -q "fixture stderr for $PLANT_FAIL" "$work/err"
    case "$PLANT_FAIL" in
    mountpoint | mount) ! grep -qE 'database-cleanup|unmount' "$PLANT_TRACE" ;;
    *) [ "$(tail -2 "$PLANT_TRACE")" = $'database-cleanup\nunmount' ] ;;
    esac
    # No later plant command may run after the first failure.
    case "$PLANT_FAIL" in
    mountpoint) [ "$(cat "$PLANT_TRACE")" = mountpoint ] ;;
    mount) ! grep -q directories "$PLANT_TRACE" ;;
    directories) ! grep -q load "$PLANT_TRACE" ;;
    load) ! grep -q digest "$PLANT_TRACE" ;;
    digest) ! grep -q image-lookup "$PLANT_TRACE" ;;
    esac
    # Cleanup must still unmount when database removal itself fails.
    if [ "$PLANT_FAIL" = database-cleanup ]; then grep -qx unmount "$PLANT_TRACE"; fi
done
for PLANT_FAIL in empty-image malformed-image; do
    export PLANT_FAIL
    run
    [ "$rc" -eq 1 ] && [ ! -s "$work/out" ]
    grep -q 'sub-step=image-lookup failed exit=1' "$work/err"
    [ "$(tail -2 "$PLANT_TRACE")" = $'database-cleanup\nunmount' ]
done
PLANT_FAIL=empty-image PLANT_CLEANUP_FAIL=unmount
run
[ "$rc" -eq 1 ] # preserve the primary failure even when cleanup returns 17.
grep -q 'sub-step=unmount failed exit=17' "$work/err"
PLANT_CLEANUP_FAIL='' PLANT_FAIL=noisy-load
run
[ "$rc" -eq 17 ] && [ ! -s "$work/out" ]
grep -q 'sub-step=load failed exit=17' "$work/err"
[ "$(wc -l <"$saved_stderr")" -gt 100 ] # full private evidence is retained.
[ "$(wc -l <"$work/err")" -le 27 ]
[ "$(awk 'length > 250 && /[|]/ {n++} END {print n+0}' "$work/err")" -eq 0 ]
! LC_ALL=C grep -q '[[:cntrl:]]' "$work/err"

# Transport failures and a success with missing/partial stdout must both fail closed.
_ssh() {
    printf 'fixture transport error\n' >"$SSH_ERR"
    return 255
}
run
[ "$rc" -eq 255 ] && [ ! -s "$work/out" ]
grep -q 'fixture transport error' "$work/err"
_ssh() {
    printf '%s\n' "$SSH_ERR" >"$work/stderr-path"
    : >"$SSH_ERR"
}
run
[ "$rc" -eq 1 ] && [ ! -s "$work/out" ]
_ssh() {
    printf '%s\n' "$SSH_ERR" >"$work/stderr-path"
    printf '123456abcdef\n'
    printf 'fixture cleanup failure\n' >"$SSH_ERR"
    return 17
}
run
[ "$rc" -eq 17 ] && [ ! -s "$work/out" ]
grep -q 'fixture cleanup failure' "$work/err"
echo 'Install keep-leg plant diagnostics: PASS'
