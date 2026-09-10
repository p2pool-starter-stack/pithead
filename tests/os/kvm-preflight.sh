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

vm_destroy() {
    local domains
    virsh destroy "$VM" >/dev/null 2>&1 || true
    virsh undefine "$VM" --nvram >/dev/null 2>&1 || true
    domains=$(virsh list --all --name) || return 1
    ! grep -Fxq "$VM" <<<"$domains"
}

vm_destroy_or_refuse() {
    vm_destroy && return
    bad "the prior test VM survived teardown"
    return 1
}

_vm_destroy_self_test() (
    local state=present
    VM=fixture
    virsh() {
        case "$1" in
        destroy | undefine) return 1 ;;
        list)
            case "$state" in present) printf 'fixture\n' ;; absent) : ;; error) return 2 ;; esac
            ;;
        esac
    }
    ! vm_destroy_or_refuse || return 1
    state=error
    ! vm_destroy_or_refuse || return 1
    state=absent
    vm_destroy_or_refuse
)

if [ "${PITHEAD_OS_VM_DESTROY_SELF_TEST:-0}" = 1 ]; then
    bad() { return 0; }
    _vm_destroy_self_test
fi
