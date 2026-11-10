#!/usr/bin/env bash
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
# shellcheck disable=SC2034
OS_RUN_SUITE=1 VM=fixture SERIAL="$work/serial" ip=''
source "$HERE/kvm-preflight.sh"
source "$HERE/fault-boot-verdict.sh"
source "$HERE/phases/fault.sh"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

virsh() { fail "phase bypassed lifecycle helpers: virsh $*"; }

reset_case() {
    : >"$work/events"
    : >"$work/rows"
    printf 'old console\n' >"$SERIAL"
    printf 'bundle\n' >"$work/update.bundle"
    ssh_waits=0 new_boot_waits=0
    printf 'v1\n' >"$work/marker"
    printf 'running\n' >"$work/state"
    printf '0\n' >"$work/stops"
    printf '0\n' >"$work/starts"
    printf '0\n' >"$work/installs"
    printf '0\n' >"$work/clock"
    STOP_FAIL_AT=0 START_FAIL=0 SSH_FAIL=0 NEW_BOOT_FAIL=0 SERIAL_MODE=boot
}

event() { printf '%s\n' "$*" >>"$work/events"; }
info() { event "info:$*"; }
ok() { printf 'ok:%s\n' "$*" >>"$work/rows"; }
bad() { printf 'bad:%s\n' "$*" >>"$work/rows"; }
sleep() { event "sleep:$1"; }
date() {
    [ "$1" = +%s ] || fail "unexpected date arguments: $*"
    local now
    now=$(($(cat "$work/clock") + 10))
    printf '%s\n' "$now" >"$work/clock"
    printf '%s\n' "$now"
}
_build_image() {
    event "build:$1"
    printf '%s\n' "$work/$1.img"
}
_build_bundle() {
    event "bundle:$1"
    printf '%s\n' "$work/update.bundle"
}
_vm_boot_disk() {
    printf 'v1\n' >"$work/marker"
    printf 'running\n' >"$work/state"
    event "boot-disk:$(basename "$1")"
}
_stage_bundle() { event stage; }
_install_cmd() { printf 'install:%s' "$1"; }
_install_and_boot_cmd() { printf 'install-boot:%s' "$1"; }
_commit_cmd() { printf commit; }
_rollback_cmd() { printf rollback; }
_marker() {
    event "marker:$(cat "$work/marker")"
    cat "$work/marker"
}
_boot_id() {
    event boot-id
    printf 'boot-%s\n' "$(cat "$work/starts")"
}
_wait_dhcp_ip() { event dhcp; }
_wait_setup_page() { event setup-page; }
_ssh_unreachable_reason() { printf unreachable; }
wait_serial() { event wait-serial; }
bundle_build_evidence() { event bundle-evidence; }
_reboot_wait() {
    event "rollback:$(cat "$work/marker")"
    printf 'v1\n' >"$work/marker"
}
_wait_new_boot() {
    new_boot_waits=$((new_boot_waits + 1))
    event "wait-new:$new_boot_waits"
    if [ "$new_boot_waits" -eq 1 ]; then printf 'v2\n' >"$work/marker"; fi
    [ "$NEW_BOOT_FAIL" -ne "$new_boot_waits" ]
}
_wait_ssh() {
    ssh_waits=$((ssh_waits + 1))
    event "wait-ssh:$ssh_waits"
    [ "$SSH_FAIL" -ne "$ssh_waits" ]
}
_ssh() {
    event "ssh:$1"
    case "$1" in
    *'dd if=/dev/urandom'*) return 0 ;;
    'install:/data/update.bundle 2>&1')
        local installs
        installs=$(($(cat "$work/installs") + 1))
        printf '%s\n' "$installs" >"$work/installs"
        if [ "$installs" -eq 1 ]; then
            printf 'corrupt bundle refused\n'
            return 42
        fi
        return 0
        ;;
    'install-boot:/data/update.bundle 2>&1') printf 'v2\n' >"$work/marker" ;;
    *"pgrep -f '[p]odman.*load'"*) return 0 ;;
    *'find "$root/overlay"'*) return 0 ;;
    esac
}

vm_stop_abrupt() {
    local count
    count=$(($(cat "$work/stops") + 1))
    printf '%s\n' "$count" >"$work/stops"
    event "stop:$count"
    [ "$STOP_FAIL_AT" -ne "$count" ] || return 1
    printf 'shut off\n' >"$work/state"
}
vm_state() {
    if [ "${1:-}" = --reason ]; then
        event state-reason
    elif [ "$#" -ne 0 ]; then
        fail "unexpected vm_state arguments: $*"
    else
        event state
    fi
    [ "$STOP_FAIL_AT" -ne "$(cat "$work/stops")" ] || return 1
    cat "$work/state"
}
vm_start() {
    local count
    count=$(($(cat "$work/starts") + 1))
    printf '%s\n' "$count" >"$work/starts"
    event "start:$count"
    [ ! -s "$SERIAL" ] || fail "start $count crossed an uncleared serial boundary"
    [ "$START_FAIL" -ne "$count" ] || return 1
    printf 'running\n' >"$work/state"
    case "$SERIAL_MODE:$count" in
    silent:1 | silent:4 | silent:5) ;;
    refusal:5) printf 'The container image store is damaged\n' >>"$SERIAL" ;;
    *) printf 'Linux version 6.1.0-fixture\n' >>"$SERIAL" ;;
    esac
}

run_phase() {
    local rc=0
    phase_fault >"$work/stdout" 2>"$work/stderr" || rc=$?
    [ "$rc" -eq 0 ] || {
        cat "$work/stdout" "$work/stderr" >&2
        fail "phase returned $rc"
    }
}

assert_sequence() {
    local last=0 found token
    for token in "$@"; do
        found=$(awk -v start="$last" -v want="$token" 'NR > start && $0 == want { print NR; exit }' "$work/events")
        [ -n "$found" ] || fail "missing ordered event '$token' after line $last"
        last=$found
    done
}

reset_case
run_phase
assert_sequence \
    build:v1 boot-disk:v1.img bundle:v2 stage \
    stop:1 state start:1 dhcp wait-ssh:2 \
    stop:2 state start:2 dhcp wait-ssh:3 \
    stop:3 state start:3 dhcp wait-ssh:4 \
    'info:fault C — install a deliberately corrupted bundle' \
    'info:installing v2 fully, then destroying mid-commit' \
    stage wait-new:1 stop:4 state start:4 dhcp wait-ssh:6 \
    'info:operator-initiated rollback' rollback:v2 marker:v1 \
    ssh:commit 'ssh:install:/data/update.bundle 2>&1' \
    'info:fault D — destroy mid first-boot image load (#1029 class)' \
    build:v1 boot-disk:v1.img wait-serial wait-ssh:7 boot-id \
    stop:5 state start:5 dhcp wait-new:2 setup-page
[ "$(cat "$work/stops")" -eq 5 ] && [ "$(cat "$work/starts")" -eq 5 ] || fail 'full lifecycle call count changed'
grep -Fq 'ok:C: a corrupt bundle is refused without crashing (exit 42)' "$work/rows" || {
    cat "$work/rows" >&2
    fail 'corrupt bundle refusal was lost'
}
grep -Fq 'ok:operator rollback works on demand (v2 -> v1)' "$work/rows" || {
    cat "$work/rows" >&2
    fail 'rollback marker transition was lost'
}
grep -Fq 'ok:still updatable after fault injection' "$work/rows" || fail 'post-fault reupdate was lost'
grep -Fq 'ok:D: install-from-stick still works afterwards' "$work/rows" || fail 'D recovery was lost'
if grep -q '^bad:' "$work/rows"; then
    cat "$work/rows" >&2
    fail 'successful lifecycle emitted a failure'
fi

for cut in 1 2 3 4 5; do
    reset_case
    STOP_FAIL_AT=$cut
    run_phase
    case "$cut" in
    1 | 2 | 3) leg="A$cut: the power cut was not confirmed" ;;
    4) leg='B: the power cut was not confirmed' ;;
    5) leg='D: the power cut during the image load was not confirmed' ;;
    esac
    grep -Fq "bad:$leg, so no boot was judged: could not read VM state" "$work/rows" ||
        fail "unreadable VM state at cut $cut did not stop its fault leg"
    [ "$(cat "$work/starts")" -eq $((cut - 1)) ] || fail "unconfirmed power cut $cut reached VM start"
done

for restart in 1 2 3 4 5; do
    reset_case
    START_FAIL=$restart
    run_phase
    case "$restart" in
    1 | 2 | 3) leg="A$restart: VM start failed after the cut" ;;
    4) leg='B: VM start failed after the cut' ;;
    5) leg='D: could not restore power after the image-load cut' ;;
    esac
    grep -Fq "bad:$leg" "$work/rows" || fail "restart failure $restart was not reported"
    [ "$(cat "$work/starts")" -eq "$restart" ] || fail "restart failure $restart did not stop its leg"
done

for diagnostic in A B D; do
    reset_case
    SERIAL_MODE=silent
    case "$diagnostic" in
    A) SSH_FAIL=2 ;;
    B) SSH_FAIL=6 ;;
    D) NEW_BOOT_FAIL=2 ;;
    esac
    run_phase
    grep -Fxq state-reason "$work/events" || fail "$diagnostic diagnostics bypassed vm_state"
    if grep -q '^virsh' "$work/events"; then fail "$diagnostic reached virsh"; fi
done

for probe in A B D; do
    reset_case
    case "$probe" in
    A)
        SSH_FAIL=2
        leg=A1
        ;;
    B)
        SSH_FAIL=6
        leg=B
        ;;
    D)
        NEW_BOOT_FAIL=2
        leg=D
        ;;
    esac
    run_phase
    grep -Fq "bad:$leg: guest booted (serial shows \"Linux version 6.1.0-fixture\") — the PROBE failed to reach it, not the boot" "$work/rows" ||
        fail "$probe boot evidence was not classified as a probe failure"
    if grep -Fxq state-reason "$work/events"; then fail "$probe probe failure requested brick diagnostics"; fi
done

reset_case
SERIAL_MODE=refusal NEW_BOOT_FAIL=2
run_phase
grep -Fq 'ok:D: refused to continue after the interrupted load, with a legible console message' "$work/rows" ||
    fail 'D legible refusal was lost'
if grep -Fxq state-reason "$work/events"; then fail 'D refusal was misclassified as a brick'; fi

printf 'fault-lifecycle selftest: PASS\n'
