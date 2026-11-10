#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC2329

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
# shellcheck source=tests/os/kvm-preflight.sh
source "$HERE/kvm-preflight.sh"
# shellcheck source=tests/os/fault-boot-verdict.sh
source "$HERE/fault-boot-verdict.sh"

fail() {
    printf 'fault-power-cut: FAIL: %s\n' "$*" >&2
    exit 1
}
VM=fixture
backend_rc=0
virsh() {
    printf '%s\n' "$*" >>"$scratch/calls"
    printf 'backend output\n'
    return "$backend_rc"
}
for operation in vm_start vm_stop_abrupt vm_state; do
    for backend_rc in 0 7; do
        rc=0
        out=$("$operation") || rc=$?
        [ "$rc" -eq "$backend_rc" ] || fail "$operation discarded the backend status"
        [ "$out" = 'backend output' ] || fail "$operation discarded the backend output"
    done
done
backend_rc=0
vm_state --reason >/dev/null
printf '%s\n' 'start fixture' 'start fixture' 'destroy fixture' 'destroy fixture' \
    'domstate fixture' 'domstate fixture' 'domstate fixture --reason' >"$scratch/expected"
cmp "$scratch/expected" "$scratch/calls" || fail 'lifecycle commands or guest differ'

virsh() { fail 'power cut bypassed the lifecycle helpers'; }
vm_stop_abrupt() {
    local count
    count=$(cat "$scratch/count")
    printf '%s\n' "$((count + 1))" >"$scratch/count"
    printf 'stop\n' >>"$scratch/calls"
    printf 'stop busy\n' >&2
    return 1
}
vm_state() {
    printf 'state\n' >>"$scratch/calls"
    case "$scenario" in
    first) printf 'shut off\n' ;;
    third) if [ "$(cat "$scratch/count")" -eq 3 ]; then printf 'shut off\n'; else printf 'running\n'; fi ;;
    never) printf 'running\n' ;;
    failed-state)
        printf 'shut off\n'
        return 2
        ;;
    empty-state) return 0 ;;
    multiline-state) printf 'shut off\nrunning\n' ;;
    esac
}
sleep() { printf 'sleep %s\n' "$*" >>"$scratch/calls"; }

for scenario in first third never failed-state empty-state multiline-state; do
    : >"$scratch/calls"
    printf '0\n' >"$scratch/count"
    rc=0
    out=$(fault_power_cut) || rc=$?
    case "$scenario" in
    first) expected_rc=0 attempts=1 expected_out='' ;;
    third) expected_rc=0 attempts=3 expected_out='' ;;
    never | multiline-state) expected_rc=1 attempts=6 expected_out='stop busy' ;;
    failed-state | empty-state) expected_rc=1 attempts=1 expected_out='could not read VM state after the power cut' ;;
    esac
    [ "$rc" -eq "$expected_rc" ] || fail "$scenario returned $rc, expected $expected_rc"
    [ "$out" = "$expected_out" ] || fail "$scenario lost its diagnostic"
    : >"$scratch/expected"
    for ((i = 1; i <= attempts; i++)); do
        printf 'stop\nstate\n' >>"$scratch/expected"
        [ "$i" -eq "$attempts" ] || printf 'sleep 10\n' >>"$scratch/expected"
    done
    cmp "$scratch/expected" "$scratch/calls" || fail "$scenario changed stop/state/retry order"
    printf 'fault-power-cut: %s PASS\n' "$scenario"
done
printf 'fault-power-cut selftest: PASS\n'
