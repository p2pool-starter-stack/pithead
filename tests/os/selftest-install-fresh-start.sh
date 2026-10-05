#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
initial="$here/phases/install.sh"
reinstall="$here/phases/install-reinstall.sh"
# The committed install precedes reinstall; Fresh Start runs after the data
# verdict but before wipe=all erases the target used by its two boots.
line() { sed -n "/$2/=" "$1" | head -1; }
[ "$(line "$initial" '_phase_install_commit || return')" -lt "$(line "$initial" '_phase_install_reinstall || return')" ]
[ "$(line "$reinstall" 'wipe=data KEPT both chains')" -lt "$(line "$reinstall" '_phase_install_fresh_start || return')" ]
[ "$(line "$reinstall" '_phase_install_fresh_start || return')" -lt "$(line "$reinstall" 'wipe=all — the data partition')" ]
grep -Fq 'source "$SCRIPT_DIR/phases/install-fresh-start.sh"' "$initial"
echo 'Fresh Start install sequence: PASS'

# Drive the actual Fresh Start leg through both target boots and the return to
# removable media. None of these doubles boots a VM or changes a real disk.
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
# shellcheck disable=SC2034 # sourced phase reads the runner's globals dynamically.
OS_RUN_SUITE=1 SERIAL="$work/serial" VM=fixture DISK=fixture-stick target_disk=fixture-target ip=fixture
# shellcheck source=tests/os/phases/install-fresh-start.sh
source "$here/phases/install-fresh-start.sh"
info() { :; }
bad() { printf 'bad:%s\n' "$1" >>"$work/trace"; }
ok() { :; }
_ssh() {
    case "$*" in
    *grub-editenv*) printf 'A_OK=1\nB_OK=0\n' ;;
    *lsblk*) printf 'vda\n' ;;
    esac
}
_genv_field() { printf '%s' "$1" | tr ' ' '\n' | sed -n "s/^$2=//p"; }
_read_genv() { printf 'A_OK=1 B_OK=0\n'; }
vm_destroy_or_refuse() { :; }
kvm_preflight() { :; }
virt-install() { printf 'boot\n' >>"$work/trace"; }
_wait_dhcp_ip() { :; }
_wait_ssh() {
    printf 'pit-ABC123\n' >"$SERIAL"
    printf 'ssh\n' >>"$work/trace"
}
_wait_setup_page() {
    page_calls=$((page_calls + 1))
    printf 'page:%s:%s\n' "$page_calls" "$1" >>"$work/trace"
    if [ "$page_calls" -eq 2 ] && [ "$page_ready" -eq 0 ]; then return 1; fi
}
curl() {
    case "$*" in
    *'/auth'*)
        while [ "$#" -gt 0 ]; do
            if [ "$1" = -c ]; then
                printf 'wizard_session\n' >"$2"
                break
            fi
            shift
        done
        ;;
    *'/handoff-ack'*) printf 200 ;;
    *'/api/handoff'*) printf '{"password":"fixture"}\n' ;;
    esac
}
provision_browser_submit() { printf 200; }
provisioning_settled() { :; }
provisioning_setup_failed() { return 1; }
provisioning_state() { printf fixture; }
_reboot_wait() { :; }
_rauc_status() { printf 'Activated: rootfs.0\n'; }
_assert_rauc_committed() { :; }
sleep() { :; }

for page_ready in 1 0; do
    : >"$work/trace"
    page_calls=0 rc=0
    _phase_install_fresh_start || rc=$?
    [ "$page_calls" -eq 2 ]
    # The returned installer has answered SSH, but must finish its disk probes
    # before the caller is allowed to continue with the destructive legs.
    [ "$(grep -c '^boot$' "$work/trace")" -eq 2 ]
    if [ "$page_ready" -eq 1 ]; then
        [ "$rc" -eq 0 ]
        [ "$(tail -2 "$work/trace")" = $'ssh\npage:2:180' ]
    else
        [ "$rc" -eq 1 ]
        grep -q '^bad:installer setup page never became ready after Fresh Start' "$work/trace"
    fi
done
echo 'Fresh Start returned-installer readiness: PASS'
