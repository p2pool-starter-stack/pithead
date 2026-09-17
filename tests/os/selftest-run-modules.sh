#!/usr/bin/env bash
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
modules=(lib/core.sh phases/boot.sh phases/update.sh phases/update-dashboard.sh phases/install.sh phases/provision.sh phases/media.sh phases/rig.sh phases/rigmedia.sh phases/fault.sh phases/reset.sh phases/image-upgrade.sh phases/crossupdate.sh)
function_files=(lib/core.sh phases/boot.sh phases/update.sh phases/update-dashboard.sh phases/install-initial.sh phases/install-reinstall.sh phases/install-restore.sh phases/install.sh phases/provision-initial.sh phases/provision-reboot.sh phases/provision-migration.sh phases/provision.sh phases/media.sh phases/rig.sh phases/rigmedia.sh phases/fault.sh phases/reset.sh phases/image-upgrade.sh phases/crossupdate.sh)
expected_modules="${modules[*]}"
actual_modules="$(sed -n 's|^source "$SCRIPT_DIR/\([a-z/-]*\.sh\)".*|\1|p' "$HERE/run.sh" | tr '\n' ' ' | sed 's/ $//')"
[ "$actual_modules" = "$expected_modules" ] || {
    echo "os module order mismatch: $actual_modules" >&2
    exit 1
}

expected_functions='ok bad info it_warn it_err have _ssh _wait_ssh _boot_id _wait_new_boot _reboot_wait _ssh_unreachable_reason _marker _dash_marker_served _wait_dhcp_ip _wait_setup_page _build_image _build_bundle _stage_bundle _install_cmd _commit_cmd _boot_spare_cmd _install_and_boot_cmd _rollback_cmd require_host require_probe_key_matches_image require_clean_bench cleanup wait_serial phase_boot _secure_boot_guest_leg _vm_boot_disk phase_update _wizard_provision_capture _os_step _serve_update_dir _leg4_srv_stop phase_update_dashboard phase_install phase_provision _make_media_stick _attach_media_stick _detach_media_stick _media_stick_has_config phase_media _rig_mining_up phase_rig _rigmedia_remove_target _rigmedia_stage_image _rigmedia_hash _rigmedia_containers _rigmedia_journal _rigmedia_before_hash_or_cleanup _rigmedia_after_hash_or_cleanup _rigmedia_containers_or_cleanup _rigmedia_journal_or_cleanup _rigmedia_quiesce _rigmedia_quiesce_or_cleanup _rigmedia_fail_cleanup phase_rigmedia phase_fault phase_reset _image_upgrade_input_failure _image_upgrade_input_run _image_upgrade_inputs_valid _image_upgrade_prepare_inputs _image_upgrade_stage_guest _image_upgrade_clear_guest_inputs phase_image_upgrade phase_crossupdate'
actual_functions="$(for module in "${function_files[@]}"; do sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\)() {.*/\1/p' "$HERE/$module"; done | grep -vE '^_phase_(install|provision)_' | tr '\n' ' ' | sed 's/ $//')"
[ "$actual_functions" = "$expected_functions" ] || {
    echo "os function order or completeness mismatch" >&2
    exit 1
}

if bash -c 'source "$1"' _ "$HERE/phases/boot.sh" >/dev/null 2>&1; then
    echo "os module accepted a direct source without its runner guard" >&2
    exit 1
fi

OS_RUN_SUITE=1 SCRIPT_DIR="$HERE" SERIAL="$(mktemp)" PASS=0 FAIL=0 KEEP=1
VM=selftest DISK="$SERIAL.disk" SSH_ERR="$SERIAL.ssh-error"
# shellcheck source=tests/os/lib/core.sh
source "$HERE/lib/core.sh" || exit $?
# shellcheck source=tests/os/phases/boot.sh
source "$HERE/phases/boot.sh" || exit $?
# shellcheck source=tests/os/phases/update.sh
source "$HERE/phases/update.sh" || exit $?
# shellcheck source=tests/os/phases/update-dashboard.sh
source "$HERE/phases/update-dashboard.sh" || exit $?
# shellcheck source=tests/os/phases/install.sh
source "$HERE/phases/install.sh" || exit $?
# shellcheck source=tests/os/phases/provision.sh
source "$HERE/phases/provision.sh" || exit $?
# shellcheck source=tests/os/phases/media.sh
source "$HERE/phases/media.sh" || exit $?
# shellcheck source=tests/os/phases/rig.sh
source "$HERE/phases/rig.sh" || exit $?
# shellcheck source=tests/os/phases/rigmedia.sh
source "$HERE/phases/rigmedia.sh" || exit $?
# shellcheck source=tests/os/phases/fault.sh
source "$HERE/phases/fault.sh" || exit $?
# shellcheck source=tests/os/phases/reset.sh
source "$HERE/phases/reset.sh" || exit $?
# shellcheck source=tests/os/phases/image-upgrade.sh
source "$HERE/phases/image-upgrade.sh" || exit $?
# shellcheck source=tests/os/phases/crossupdate.sh
source "$HERE/phases/crossupdate.sh" || exit $?
trap - EXIT
if (
    REMOTE_MONERO_HOST=node.example REMOTE_MONERO_RPC_PORT=18081 REMOTE_MONERO_ZMQ_PORT=18083 \
        REMOTE_TARI_HOST=tari.example PITHEAD_REGISTRY=registry.example
    _image_upgrade_inputs_valid
); then
    :
else
    echo "image-upgrade rejected the complete remote-node contract" >&2
    exit 1
fi
diagnostic_rc=0
diagnostic="$(_image_upgrade_input_run generated-config \
    'tar -xOf <baseline> pithead/config.reference.json | jq <config-transform>' \
    sh -c 'printf "must-not-leak\n" >&2; exit 17' 2>&1)" || diagnostic_rc=$?
[ "$diagnostic_rc" -eq 17 ] &&
    [ "$diagnostic" = 'image-upgrade input failure: sub-step=generated-config command="tar -xOf <baseline> pithead/config.reference.json | jq <config-transform>" exit=17' ] || {
    echo "image-upgrade failure attribution lost the sub-step, redacted command, or exit status" >&2
    exit 1
}
if (
    REMOTE_MONERO_HOST=node.example REMOTE_MONERO_RPC_PORT=18081 REMOTE_MONERO_ZMQ_PORT='' \
        REMOTE_TARI_HOST=tari.example PITHEAD_REGISTRY=registry.example
    _image_upgrade_inputs_valid
); then
    echo "image-upgrade accepted a missing remote-node input" >&2
    exit 1
fi
if (
    td="$(mktemp -d)" && trap 'rm -rf "$td"' EXIT
    REMOTE_MONERO_HOST=node.example REMOTE_MONERO_RPC_PORT=18081 REMOTE_MONERO_ZMQ_PORT=18083
    REMOTE_TARI_HOST=tari.example PITHEAD_REGISTRY=registry.example IMAGE=fixture
    _image_upgrade_prepare_inputs() { :; }
    _vm_boot_disk() { :; }
    _wait_ssh() { :; }
    _image_upgrade_stage_guest() { return 1; }
    _ssh() { [ "$1" = 'rm -rf /run/pithead-image-upgrade' ] && : >"$td/guest-inputs-cleared"; }
    bad() { :; }
    info() { :; }
    phase_image_upgrade
    [ -e "$td/guest-inputs-cleared" ] && rm -rf "$IMAGE_UPGRADE_HOST_STAGE"
); then
    :
else
    echo "image-upgrade left staged guest inputs after a staging failure" >&2
    exit 1
fi
for fn in $expected_functions; do type "$fn" >/dev/null 2>&1 || exit 1; done
for fn in _phase_install_initial _phase_install_reinstall _phase_install_restore _phase_provision_initial _phase_provision_reboot _phase_provision_migration; do type "$fn" >/dev/null 2>&1 || exit 1; done
preflight_cleanup="$(sed -n '/kvm_preflight || {/,/^    }/p' "$HERE/phases/rigmedia.sh")"
grep -Fq '_rigmedia_fail_cleanup "$target_disk"' <<<"$preflight_cleanup" || exit 1
target_create="$(sed -n '/qemu-img create -f raw/,/^    }/p' "$HERE/phases/rigmedia.sh")"
grep -Fq 'could not create the blank internal target disk' <<<"$target_create" || exit 1
for evidence in 'could not hash the blank internal target disk' 'could not list containers after stick-run rig handoff' 'could not inspect journald after stick-run rig handoff' 'could not hash the internal target disk after the rig run'; do
    grep -Fq "$evidence" "$HERE/phases/rigmedia.sh" || exit 1
done
expected_all='phase_boot phase_update phase_install phase_provision phase_rig phase_rigmedia phase_media phase_fault phase_reset phase_image_upgrade'
actual_all="$(sed -n '/^all)/,/^    ;;/p' "$HERE/run.sh" | sed -n 's/^    \(phase_[a-z_]*\)$/\1/p' | tr '\n' ' ' | sed 's/ $//')"
[ "$actual_all" = "$expected_all" ] || exit 1
(
    actions="" bads=0 destroy_ok=1 list_ok=1 vm_destroy_ok=1 hash_ok=1 ssh_ok=1 copy_ok=1
    bad() { bads=$((bads + 1)); }
    vm_destroy_or_refuse() {
        actions+="undefine "
        [ "$vm_destroy_ok" = 1 ] || {
            bad "the prior test VM survived teardown"
            return 1
        }
    }
    virsh() {
        case "$1" in
        list)
            [ "$list_ok" = 1 ] || return 1
            printf '%s\n' "$VM"
            ;;
        destroy)
            actions+="destroy "
            [ "$destroy_ok" = 1 ]
            ;;
        esac
    }
    rm() { actions+="rm:$2 "; }
    cp() { [ "$copy_ok" = 1 ]; }
    sha256sum() { [ "$hash_ok" = 1 ] && printf 'hash  %s\n' "$1"; }
    _ssh() {
        [ "$ssh_ok" = 1 ] || return 1
        case "$1" in *journald*) printf '1\n' ;; *) printf 'one\r\ntwo\n' ;; esac
    }
    _rigmedia_stage_image image disk || exit 1
    copy_ok=0
    ! _rigmedia_stage_image image disk || exit 1
    [ "$bads" -eq 1 ] || exit 1
    copy_ok=1 bads=0
    [ "$(_rigmedia_hash target)" = hash ] || exit 1
    hash_ok=0
    ! _rigmedia_hash target || exit 1
    hash_ok=1
    [ "$(_rigmedia_containers)" = 'one two' ] || exit 1
    [ "$(_rigmedia_journal)" = 1 ] || exit 1
    ssh_ok=0
    ! _rigmedia_containers || exit 1
    actions="" bads=0 KEEP=0 vm_destroy_ok=1 hash_ok=0
    ! _rigmedia_before_hash_or_cleanup target || exit 1
    [ "$actions" = "undefine rm:target " ] || exit 1
    [ "$bads" -eq 1 ] || exit 1
    actions="" bads=0
    ! _rigmedia_after_hash_or_cleanup target || exit 1
    [ "$actions" = "rm:target " ] || exit 1
    [ "$bads" -eq 1 ] || exit 1
    hash_ok=1 actions="" bads=0
    ! _rigmedia_containers_or_cleanup target || exit 1
    [ "$actions" = "undefine rm:target " ] || exit 1
    [ "$bads" -eq 1 ] || exit 1
    actions="" bads=0
    ! _rigmedia_journal_or_cleanup target || exit 1
    [ "$actions" = "undefine rm:target " ] || exit 1
    [ "$bads" -eq 1 ] || exit 1
    ssh_ok=1
    actions="" bads=0
    KEEP=1
    _rigmedia_quiesce && _rigmedia_remove_target target || exit 1
    [ "$actions" = "destroy " ] || exit 1
    actions=""
    destroy_ok=0
    ! _rigmedia_quiesce || exit 1
    [ "$actions" = "destroy " ] || exit 1
    [ "$bads" -eq 1 ] || exit 1
    actions="" bads=0 destroy_ok=1
    KEEP=0
    _rigmedia_quiesce && _rigmedia_remove_target target || exit 1
    [ "$actions" = "undefine rm:target " ]
    actions="" vm_destroy_ok=0
    ! _rigmedia_quiesce || exit 1
    [ "$actions" = "undefine " ] || exit 1
    [ "$bads" -eq 1 ] || exit 1
    actions="" bads=0
    ! _rigmedia_quiesce_or_cleanup target || exit 1
    [ "$actions" = "undefine undefine " ] || exit 1
    [ "$bads" -eq 2 ] || exit 1
    vm_destroy_ok=1
    actions=""
    KEEP=1
    _rigmedia_fail_cleanup target || exit 1
    [ "$actions" = "destroy " ]
    actions="" destroy_ok=0
    ! _rigmedia_fail_cleanup target || exit 1
    [ "$actions" = "destroy " ]
    actions="" bads=0 destroy_ok=1 list_ok=1 vm_destroy_ok=1 KEEP=0
    _rigmedia_fail_cleanup target || exit 1
    [ "$actions" = "undefine rm:target " ] || exit 1
    actions="" vm_destroy_ok=0
    ! _rigmedia_fail_cleanup target || exit 1
    [ "$actions" = "undefine " ] || exit 1
    [ "$bads" -eq 1 ] || exit 1
    actions="" KEEP=1 list_ok=0
    ! _rigmedia_fail_cleanup target || exit 1
    [ -z "$actions" ]
) || exit 1
(
    bads=0 create_called=0 KEEP=0
    _build_image() { printf 'image\n'; }
    vm_destroy_or_refuse() { :; }
    rm() { :; }
    cp() { :; }
    qemu-img() {
        case "$1" in
        resize) : ;;
        create)
            create_called=1
            return 1
            ;;
        esac
    }
    bad() { bads=$((bads + 1)); }
    phase_rigmedia
    [ "$create_called" -eq 1 ] || exit 1
    [ "$bads" -eq 1 ]
) || exit 1
rm -f "$SERIAL" "$SERIAL.failed"
echo "os-run-modules: PASS"
