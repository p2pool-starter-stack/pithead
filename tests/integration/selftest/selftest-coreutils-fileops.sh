#!/usr/bin/env bash
set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
source "$HERE/../lib.sh"

REPO="$(cd -P "$HERE/../../.." && pwd -P)"

cfo() { (
    source "$REPO/pithead" </dev/null >/dev/null 2>&1
    "$@"
); }

ROOT=$(mktemp -d)
trap 'rm -rf -- "$ROOT"' EXIT

cfo_replace_case() {
    mkdir -p "$1" || return 1
    printf 'NEW\n' >"$1/src"
    printf 'OLD\n' >"$1/dest"
    chmod 644 "$1/dest"
    install_file "$1/src" "$1/dest" || return 1
    [ "$(cat "$1/dest")" = NEW ] && [ "$(stat -c '%a' "$1/dest")" = 600 ] &&
        [ -z "$(find "$1" -maxdepth 1 -name 'dest.pithead.*' -print -quit)" ]
}

cfo_mode_case() {
    mkdir -p "$1" || return 1
    printf 'PUB\n' >"$1/pub-src"
    install_file "$1/pub-src" "$1/pub" 644 || return 1
    [ "$(stat -c '%a' "$1/pub")" = 644 ]
}

cfo_failure_case() {
    mkdir -p "$1" || return 1
    printf 'KEEP\n' >"$1/keep"
    chmod 640 "$1/keep"
    install_file "$1/no-such-source" "$1/keep" 2>/dev/null && return 1
    [ "$(cat "$1/keep")" = KEEP ] && [ "$(stat -c '%a' "$1/keep")" = 640 ] &&
        [ -z "$(find "$1" -maxdepth 1 -name 'keep.pithead.*' -print -quit)" ]
}

cfo_marker_case() {
    mkdir -p "$1" || return 1
    install_file /dev/null "$1/marker" || return 1
    [ -f "$1/marker" ] && [ ! -s "$1/marker" ] && [ "$(stat -c '%a' "$1/marker")" = 600 ]
}

cfo_restore_case() {
    mkdir -p "$1" || return 1
    printf 'ARCHIVE\n' >"$1/arch"
    printf 'STALE\n' >"$1/rdest"
    chmod 644 "$1/rdest"
    restore_setup_publish_file "$1/arch" "$1/rdest" || return 1
    [ "$(cat "$1/rdest")" = ARCHIVE ] && [ "$(stat -c '%a' "$1/rdest")" = 600 ] &&
        [ -z "$(find "$1" -maxdepth 1 -name 'rdest.restore.*' -print -quit)" ]
}

cfo_spool_case() {
    local spool="$1" snap rc=0
    wizard_spool_publish "$spool" config.json printf %s spooled || return 1
    [ "$(cat "$spool/config.json")" = spooled ] || return 1
    wizard_spool_publish "$spool" big.txt printf %s xxxxxxxxxxxx || return 1
    snap=$(wizard_spool_snapshot "$spool" big.txt 4) || rc=$?
    [ "$rc" = 3 ] || return 1
    [ ! -e "$snap" ] || return 1
    snap=$(wizard_spool_snapshot "$spool" config.json 64) || return 1
    [ "$(cat "$snap")" = spooled ]
}

cfo_sync_case() {
    local root="$1"
    mkdir -p "$root/sync-src" "$root/sync-dst" || return 1
    printf '#!/bin/sh\n' >"$root/sync-src/pithead"
    printf '1.0.0\n' >"$root/sync-src/VERSION"
    printf 'k\n' >"$root/sync-src/cosign.pub"
    printf 'CA\n' >"$root/sync-src/cosign.registry-ca.crt"
    (
        cd "$REPO" || exit 1
        PITHEAD_SYNC_SRC="$root/sync-src" PITHEAD_SYNC_DST="$root/sync-dst" \
            PITHEAD_SYNC_RIGFORGE_SRC="$root/no-rigforge" \
            bash os/overlay/pithead-sync >/dev/null 2>&1
    ) || return 1
    [ "$(cat "$root/sync-dst/VERSION")" = 1.0.0 ] || return 1
    [ "$(stat -c '%a' "$root/sync-dst/VERSION")" = 644 ] || return 1
    [ -x "$root/sync-dst/pithead" ] || return 1
    [ "$(cat "$root/sync-dst/cosign.registry-ca.crt")" = CA ] || return 1
    [ -z "$(find "$root/sync-dst" -name '*.pithead.*' -print -quit)" ] || return 1
    rm -f "$root/sync-src/cosign.registry-ca.crt"
    (
        cd "$REPO" || exit 1
        PITHEAD_SYNC_SRC="$root/sync-src" PITHEAD_SYNC_DST="$root/sync-dst" \
            PITHEAD_SYNC_RIGFORGE_SRC="$root/no-rigforge" \
            bash os/overlay/pithead-sync >/dev/null 2>&1
    ) || return 1
    [ ! -e "$root/sync-dst/cosign.registry-ca.crt" ]
}

cfo_boot_case() {
    local root="$1"
    mkdir -p "$root/boot" || return 1
    printf '#!/bin/sh\necho status-ok\n' >"$root/boot/pithead"
    chmod 755 "$root/boot/pithead"
    (
        cd "$root/boot" || exit 1
        source "$REPO/os/overlay/pithead-boot-stack-health" </dev/null >/dev/null 2>&1
        export BOOT_STATUS_LOG="$root/boot/status.log"
        boot_status
    ) || return 1
    [ "$(cat "$root/boot/status.log")" = status-ok ] || return 1
    [ "$(stat -c '%a' "$root/boot/status.log")" = 600 ] || return 1
    [ -z "$(find "$root/boot" -name 'status.log.pithead.*' -print -quit)" ]
}

cfo_banner_case() { coreutils_banner | grep -qiE 'coreutils|stat'; }

cfo_probe_case() { detect_coreutils && [ "${#GNU_FEATURES[@]}" -eq 0 ]; }

run_case() {
    local label="$1"
    shift
    if cfo "$@"; then
        it_pass "$label"
    else
        it_fail "$label"
    fi
}

echo "== unit: install_file lands by rename, never in place (#4495) =="
run_case "install_file replaces an existing destination at 600, temp cleaned up" \
    cfo_replace_case "$ROOT/replace"
run_case "install_file honors an explicit mode on a new destination" \
    cfo_mode_case "$ROOT/mode"
run_case "install_file failure leaves destination bytes and mode untouched, temp cleaned up" \
    cfo_failure_case "$ROOT/failure"
run_case "install_file /dev/null creates the empty 600 marker the wizard stages" \
    cfo_marker_case "$ROOT/marker"

echo "== unit: the operations stack suites stub, unstubbed (#4495) =="
run_case "restore_setup_publish_file publishes over an existing destination (cp stub removed)" \
    cfo_restore_case "$ROOT/restore"
run_case "wizard-spool publish (mv -T) and snapshot (ln -P, stat -c, head -c) round-trip, oversize refused (cp/mv stubs removed)" \
    cfo_spool_case "$ROOT/spool"
run_case "pithead-sync lands the program tree at 644 by rename and drops the absent CA" \
    cfo_sync_case "$ROOT/sync"
run_case "boot_status lands its 0600 status log by rename before the redirect fills it" \
    cfo_boot_case "$ROOT/bootc"

echo "== unit: doctor names the coreutils implementation it probes (#4495) =="
if [ "$(uname -s)" = Linux ]; then
    run_case "coreutils_banner names the implementation" cfo_banner_case
    run_case "detect_coreutils finds every needed behavior on this runner ($(uname -sr))" \
        cfo_probe_case
else
    it_pass "detect_coreutils behavior asserts are Linux-only; BSD userland is out of scope (#4495)"
fi

echo "selftest-coreutils-fileops: $IT_PASS passed, $IT_FAIL failed"
[ "$IT_FAIL" -eq 0 ] || exit 1
