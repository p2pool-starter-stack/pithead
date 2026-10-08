#!/usr/bin/env bash
set -euo pipefail
export TMPDIR="${TMPDIR:-${RUNNER_TEMP:?set TMPDIR or RUNNER_TEMP}}"
HERE=$(cd "$(dirname "$0")" && pwd)
python3 "$HERE/selftest-migration-local-chain.py"
# shellcheck source=tests/os/migration-local-chain.sh
source "$HERE/migration-local-chain.sh"
SCRIPT_DIR=$HERE
bad() { :; }
if migration_snapshot_input; then
    echo 'FAIL: missing local-chain fixture passed'
    exit 1
fi
# A missing reserved Tari port must refuse before capture or mutation.
(
    calls=$(mktemp "${TMPDIR:?}/migration-tari-input.XXXXXX")
    rm -f "$calls"
    trap 'rm -f "$calls"' EXIT
    getent() { echo "127.0.0.1 fixture"; }
    sensitive_live_config() {
        echo read >"$calls"
        return 99
    }
    unset PITHEAD_OS_TARI_GRPC_PORT
    if migration_prepare_local_chain; then exit 1; fi
    [ ! -e "$calls" ]
) || {
    echo "FAIL: omitted reserved Tari input reached configuration"
    exit 1
}
# The polling contract must observe advancing hashes, not just a carried positive counter.
for mode in advancing stalled malformed unhealthy; do
    T=$(mktemp -d "${TMPDIR:?}/migration-poll.XXXXXX")
    printf '0\n' >"$T/time"
    printf '10\n' >"$T/hashes"
    date() {
        local n
        n=$(cat "$T/time")
        echo "$n"
        echo "$((n + 600))" >"$T/time"
    }
    sleep() { :; }
    _ssh() {
        local h
        h=$(cat "$T/hashes")
        if [ "$mode" = advancing ]; then echo "$((h + 1))" >"$T/hashes"; fi
        if [ "$mode" = malformed ]; then echo 'ready 2 garbage'; else echo "ready 2 $h"; fi
    }
    migration_services_healthy() { [ "$mode" != unhealthy ]; }
    MIGRATION_SNAPSHOT_HEIGHT=1
    result=fail
    if migration_wait_for_mining 0; then result=pass; fi
    if [ "$mode" = advancing ]; then expected=pass; else expected=fail; fi
    [ "$result" = "$expected" ] || {
        echo "FAIL: mining poll $mode"
        exit 1
    }
    rm -rf "$T"
done
printf 'selftest-migration-local-chain: PASS\n'
# Reject an invalid reservation before destroying a guest, and do not boot after resize failure.
# shellcheck disable=SC2034 # sourced helper reads runner scope.
OS_RUN_SUITE=1
# shellcheck source=tests/os/phases/boot.sh
source "$HERE/phases/boot.sh"
T=$(mktemp -d "${TMPDIR:?}/migration-disk.XXXXXX")
trap 'rm -rf "$T"' EXIT
# shellcheck disable=SC2034 # sourced helper reads runner scope.
DISK="$T/disk" SERIAL="$T/serial" VM=fixture
printf 'image\n' >"$T/image"
vm_destroy_or_refuse() { echo destroy >>"$T/calls"; }
qemu-img() {
    echo "$*" >>"$T/calls"
    [ "$resize_failure" = 0 ]
}
kvm_preflight() { :; }
virt-install() { echo boot >>"$T/calls"; }
_wait_dhcp_ip() { :; }
resize_failure=0
for size in 039 39 8193 bad; do
    if _vm_boot_disk "$T/image" "$size"; then
        echo 'FAIL: invalid disk size booted'
        exit 1
    fi
    [ ! -e "$T/calls" ] || {
        echo 'FAIL: invalid reservation touched guest'
        exit 1
    }
done
resize_failure=1
if _vm_boot_disk "$T/image" 100; then
    echo 'FAIL: failed resize booted'
    exit 1
fi
! grep -qx boot "$T/calls" || exit 1
resize_failure=0
_vm_boot_disk "$T/image" 100
[ "$(grep -c '^resize .* 100G$' "$T/calls")" = 2 ] || exit 1
grep -qx boot "$T/calls" || exit 1
printf 'selftest-migration-guest-capacity: PASS\n'
