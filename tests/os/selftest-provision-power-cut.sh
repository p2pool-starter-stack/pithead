#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
# shellcheck disable=SC2034
OS_RUN_SUITE=1 VM=fixture ip=fixture

# shellcheck source=tests/os/kvm-preflight.sh
source "$HERE/kvm-preflight.sh"
# shellcheck source=tests/os/m10-height-verdict.sh
source "$HERE/m10-height-verdict.sh"
# shellcheck source=tests/os/phases/provision-power-cut.sh
source "$HERE/phases/provision-power-cut.sh"

fail() {
    printf 'provision-power-cut selftest: FAIL: %s\n' "$*" >&2
    exit 1
}

expect_rc() {
    local expected="$1" got=0
    shift
    "$@" >"$scratch/output" 2>&1 || got=$?
    [ "$got" -eq "$expected" ] || fail "expected rc $expected, got $got from $*"
}

type vm_stop_abrupt >/dev/null 2>&1 || fail 'vm_stop_abrupt is missing'
type vm_start >/dev/null 2>&1 || fail 'vm_start is missing'

virsh_rc=0
virsh() {
    printf '%s\n' "$*" >>"$scratch/virsh"
    return "$virsh_rc"
}

: >"$scratch/virsh"
# shellcheck disable=SC2218
vm_stop_abrupt
# shellcheck disable=SC2218
vm_start
printf '%s\n' "destroy $VM" "start $VM" >"$scratch/expected"
cmp -s "$scratch/expected" "$scratch/virsh" || fail 'lifecycle wrappers passed unexpected virsh arguments'
! grep -Fq undefine "$scratch/virsh" || fail 'power-cycle wrappers undefine the guest'
virsh_rc=17
expect_rc 17 vm_stop_abrupt
virsh_rc=23
expect_rc 23 vm_start
virsh_rc=0
virsh() {
    record "raw-virsh:$*"
    return 99
}

actions="$scratch/actions"
verdicts="$scratch/verdicts"
mode=success

record() { printf '%s\n' "$1" >>"$actions"; }
info() { :; }
ok() { :; }
bad() { printf '%s\n' "$1" >>"$verdicts"; }
sleep() { record "sleep:$1"; }
date() {
    local now
    now=$(($(cat "$scratch/clock") + 100))
    printf '%s\n' "$now" >"$scratch/clock"
    printf '%s\n' "$now"
}
curl() {
    record recovery-dashboard
    printf '200'
}
_monerod_height() {
    record height
    printf '100\n'
}
_boot_id() {
    local cycle
    cycle=$(($(cat "$scratch/cycle") + 1))
    printf '%s\n' "$cycle" >"$scratch/cycle"
    record boot-id
    printf 'boot-%s\n' "$cycle"
}
vm_stop_abrupt() {
    record power-cut
    [ "$mode" != cut-fails ]
}
vm_start() {
    record start
    [ "$mode" != start-fails ]
}
_wait_new_boot() {
    record "new-boot:$1:$2"
    [ "$mode" != boot-fails ]
}
provisioning_settled() {
    record "provision-settled:$1"
    return 0
}
provisioning_setup_failed() {
    record provision-failed
    return 1
}
provisioning_state() { printf ready; }
_monerod_evidence() { record recovery-evidence; }
_ssh() {
    case "$1" in
    sync)
        record sync
        return 0
        ;;
    "podman ps --format '{{.Names}}'")
        if [ "$(cat "$scratch/cycle")" -eq 0 ]; then
            printf 'worker\n'
        else
            record container
            printf 'worker\n'
        fi
        ;;
    "podman images --format '{{.Repository}}:{{.Tag}}@{{.Digest}}'")
        [ "$(cat "$scratch/cycle")" -gt 0 ] && record recovery-images
        printf 'image:tag@digest\n'
        ;;
    "grub-editenv /boot/efi/grub/grubenv list 2>/dev/null | grep -E '^(A_OK|A_TRY)=' | LC_ALL=C sort")
        printf 'A_OK=1\nA_TRY=0\n'
        ;;
    'root=$(podman info --format "{{.Store.GraphRoot}}" 2>/dev/null); find "$root/overlay" -maxdepth 2 -name lower -size 0 -print -quit 2>/dev/null')
        record recovery-store
        ;;
    "systemctl is-active --quiet xmrig && pgrep -x xmrig >/dev/null")
        record recovery-miner
        ;;
    "grub-editenv /boot/efi/grub/grubenv list")
        record recovery-slot
        printf 'A_OK=1\nA_TRY=0\n'
        ;;
    *)
        fail "unexpected guest command: $1"
        ;;
    esac
}

run_phase() {
    mode="$1"
    printf '0\n' >"$scratch/cycle"
    printf '0\n' >"$scratch/clock"
    : >"$actions"
    : >"$verdicts"
    _phase_provision_power_cut
}

run_phase success || fail "three-cycle success path failed after $(tail -1 "$actions"): $(tail -1 "$verdicts")"
for i in 1 2 3; do
    printf '%s\n' \
        height sync boot-id power-cut sleep:3 start "new-boot:boot-$i:300" \
        container provision-settled:900 provision-failed recovery-store recovery-images \
        height recovery-miner recovery-dashboard recovery-slot
done >"$scratch/expected"
cmp -s "$scratch/expected" "$actions" || {
    diff -u "$scratch/expected" "$actions" >&2 || true
    fail 'three-cycle action order changed'
}

for case_name in cut-fails start-fails boot-fails; do
    rc=0
    run_phase "$case_name" || rc=$?
    [ "$rc" -eq 1 ] || fail "$case_name returned $rc"
    case "$case_name" in
    cut-fails)
        expected='M10.1: could not cut power'
        tail_action=power-cut
        ;;
    start-fails)
        expected='M10.1: could not restore power'
        tail_action=start
        ;;
    boot-fails)
        expected='M10.1: BRICKED — no boot after a power cut with the stack live (disqualifying)'
        tail_action='new-boot:boot-1:300'
        ;;
    esac
    [ "$(cat "$verdicts")" = "$expected" ] || fail "$case_name emitted the wrong diagnostic"
    [ "$(tail -1 "$actions")" = "$tail_action" ] || fail "$case_name did not abort immediately"
    ! grep -Eq '^(container|provision-|recovery-)' "$actions" || fail "$case_name continued into recovery"
done

printf 'provision-power-cut selftest: PASS\n'
