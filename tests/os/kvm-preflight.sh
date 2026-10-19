# shellcheck shell=bash
#
# KVM pre-flight for the battery (#1059, #1664): refuse to boot the 16 GiB guest when the host
# cannot back it. Sourced by tests/os/run.sh, which defines bad() and calls this immediately
# before every virt-install. The KVM host also hosts the fleet: a memory hang there takes every
# lane down and needs the operator's hands to recover, so a refused boot is a finding and a hang
# is a lost box (two host hangs on 2026-09-02/03; the second with the guest up). The bar is the
# guest plus a 4 GiB margin; MemAvailable already counts reclaimable cache, so it is the honest
# "what the guest can take without swapping" figure. The reading is printed either way, so every
# boot leaves the number the next reader will want. PITHEAD_KVM_MIN_AVAIL_MB raises or lowers
# the bar; PITHEAD_KVM_MEMINFO points the read at a fixture so both branches are provable
# without a guest.
kvm_preflight() {
    local need avail
    need=${PITHEAD_KVM_MIN_AVAIL_MB:-20480}
    avail=$(awk '/^MemAvailable:/{printf "%d", $2 / 1024}' "${PITHEAD_KVM_MEMINFO:-/proc/meminfo}")
    printf '     · host MemAvailable=%s MiB before the guest boots (bar %s MiB)\n' "$avail" "$need"
    [ "$avail" -ge "$need" ] && return 0
    bad "KVM PRE-FLIGHT REFUSED: host MemAvailable ${avail} MiB is under the ${need} MiB bar — not booting the 16 GiB guest (#1059: the condition that hung the host)"
    return 1
}

_vm_teardown_step() {
    local t0 rc=0 secs
    t0=$(date +%s)
    timeout -k 10 "${PITHEAD_VM_TEARDOWN_TIMEOUT:-60}" virsh "$@" 2>/dev/null || rc=$?
    secs=$(($(date +%s) - t0))
    printf '     · teardown: virsh %s took %ss (rc %s)\n' "$1" "$secs" "$rc" >&2
    if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
        printf '     · teardown: virsh %s timed out; still running:\n' "$1" >&2
        ps -eo pid,ppid,stat,etimes,wchan:32,args 2>/dev/null | grep -F -- "$VM" | grep -v grep >&2 || true
        ps -o pid,stat,etimes,args --ppid "$$" >&2 2>/dev/null || true
    fi
    return "$rc"
}

vm_destroy() {
    local domains
    _vm_teardown_step destroy "$VM" >/dev/null || true
    _vm_teardown_step undefine "$VM" --nvram >/dev/null || true
    domains=$(_vm_teardown_step list --all --name) || return 1
    ! grep -Fxq "$VM" <<<"$domains"
}

vm_destroy_or_refuse() {
    vm_destroy && return
    bad "the prior test VM survived teardown"
    return 1
}

_vm_destroy_hang_self_test() {
    local log rc=0 call expected=124 started
    started=$(date +%s)
    log=$(STATE="$1" PITHEAD_VM_TEARDOWN_TIMEOUT=0.1 vm_destroy_or_refuse 2>&1) || rc=$?
    [ "$rc" -ne 0 ] || return 1
    if [ "$1" = term-ignoring ]; then
        expected=137
        [ "$(($(date +%s) - started))" -le 12 ] || return 1
    else
        [ "$(($(date +%s) - started))" -le 3 ] || return 1
    fi
    for call in destroy undefine list; do
        grep -qE "virsh $call took [0-9]+s \(rc [0-9]+\)" <<<"$log" || return 1
    done
    case "$1" in
        both-hung) call='destroy undefine' ;;
        term-ignoring) call=destroy ;;
        list-hung) call=list ;;
    esac
    for call in $call; do
        grep -qE "virsh $call took [0-9]+s \(rc $expected\)" <<<"$log" || return 1
        grep -q "virsh $call timed out; still running" <<<"$log" || return 1
    done
    grep -q fixture-qemu <<<"$log" || return 1
    grep -q fixture-child <<<"$log"
}

_vm_destroy_self_test() (
    local bin state failures=0
    bin=$(mktemp -d)
    trap 'rm -rf "$bin"' EXIT
    cat >"$bin/virsh" <<'STUB'
#!/usr/bin/env bash
case "$STATE:$1" in
both-hung:destroy | both-hung:undefine | list-hung:list) exec sleep 30 ;;
term-ignoring:destroy) trap '' TERM; exec sleep 30 ;;
esac
case "$1" in
destroy | undefine) exit 1 ;;
list) case "$STATE" in present | both-hung | term-ignoring) echo fixture ;; error) exit 2 ;; esac ;;
esac
STUB
    cat >"$bin/ps" <<'STUB'
#!/usr/bin/env bash
case "$1" in -eo) echo fixture-qemu ;; -o) echo fixture-child ;; esac
STUB
    chmod +x "$bin/virsh" "$bin/ps"
    unset -f virsh ps
    PATH="$bin:$PATH"
    VM=fixture
    export STATE=present
    ! vm_destroy_or_refuse 2>/dev/null || return 1
    STATE=error
    ! vm_destroy_or_refuse 2>/dev/null || return 1
    STATE=absent
    vm_destroy_or_refuse 2>/dev/null || return 1
    for state in both-hung term-ignoring list-hung; do
        if _vm_destroy_hang_self_test "$state"; then
            printf 'vm-destroy: %s PASS\n' "$state"
        else
            printf 'vm-destroy: %s FAIL\n' "$state" >&2
            failures=$((failures + 1))
        fi
    done
    [ "$failures" -eq 0 ]
)

if [ "${PITHEAD_OS_VM_DESTROY_SELF_TEST:-0}" = 1 ]; then
    bad() { return 0; }
    _vm_destroy_self_test
fi
