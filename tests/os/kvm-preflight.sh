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

# Teardown is bounded and timed (#2727): job 1194 sat 13 minutes in this function after a full
# stack phase with no line saying which call held it. Every virsh call gets its own ceiling
# (PITHEAD_VM_TEARDOWN_TIMEOUT, default 180 s: libvirt's own destroy escalates to SIGKILL within
# seconds, so a longer wait is qemu stuck, not slow). Each call prints its duration, and one that
# times out or fails prints the guest's qemu processes (state and kernel wait channel) and
# whatever this shell still has running, so the next occurrence names itself. A timed-out
# destroy leaves the domain listed, so the check below still refuses rather than passes.
_vm_teardown_step() {
    local t0 rc=0 secs
    t0=$(date +%s)
    timeout "${PITHEAD_VM_TEARDOWN_TIMEOUT:-180}" virsh "$@" >/dev/null 2>&1 || rc=$?
    secs=$(($(date +%s) - t0))
    printf '     · teardown: virsh %s took %ss (rc %s)\n' "$1" "$secs" "$rc" >&2
    [ "$rc" -eq 124 ] || return 0
    printf '     · teardown: virsh %s timed out; still running:\n' "$1" >&2
    ps -eo pid,ppid,stat,etimes,wchan:32,args 2>/dev/null | grep -F -- "$VM" | grep -v grep >&2
    ps -o pid,stat,etimes,args --ppid "$$" >&2 2>/dev/null
    return 0
}

vm_destroy() {
    local domains
    _vm_teardown_step destroy "$VM"
    _vm_teardown_step undefine "$VM" --nvram
    domains=$(timeout "${PITHEAD_VM_TEARDOWN_TIMEOUT:-180}" virsh list --all --name) || return 1
    ! grep -Fxq "$VM" <<<"$domains"
}

vm_destroy_or_refuse() {
    vm_destroy && return
    bad "the prior test VM survived teardown"
    return 1
}

# virsh is a PATH stub, not a function: the teardown runs it under timeout(1), which execs.
_vm_destroy_self_test() (
    local bin log
    bin=$(mktemp -d)
    trap 'rm -rf "$bin"' EXIT
    cat >"$bin/virsh" <<'STUB'
#!/usr/bin/env bash
case "$1" in
destroy) [ "$STATE" = hung ] && exec sleep 5; exit 1 ;;
undefine) exit 1 ;;
list) case "$STATE" in present | hung) echo fixture ;; error) exit 2 ;; esac ;;
esac
STUB
    chmod +x "$bin/virsh"
    PATH="$bin:$PATH"
    VM=fixture
    export STATE=present
    ! vm_destroy_or_refuse 2>/dev/null || return 1
    STATE=error
    ! vm_destroy_or_refuse 2>/dev/null || return 1
    STATE=absent
    vm_destroy_or_refuse 2>/dev/null || return 1
    # A hung virsh is cut at the ceiling and named, and the surviving domain still refuses.
    STATE=hung
    log=$(PITHEAD_VM_TEARDOWN_TIMEOUT=1 vm_destroy_or_refuse 2>&1) && return 1
    grep -qE 'virsh destroy took [0-9]+s \(rc 124\)' <<<"$log" || return 1
    grep -q 'virsh destroy timed out; still running' <<<"$log"
)

if [ "${PITHEAD_OS_VM_DESTROY_SELF_TEST:-0}" = 1 ]; then
    bad() { return 0; }
    _vm_destroy_self_test
fi
