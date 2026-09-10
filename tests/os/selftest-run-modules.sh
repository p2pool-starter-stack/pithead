#!/usr/bin/env bash
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
modules=(lib/core.sh phases/boot.sh phases/update.sh phases/update-dashboard.sh phases/install.sh phases/provision.sh phases/media.sh phases/rig.sh phases/fault.sh phases/reset.sh)
function_files=(lib/core.sh phases/boot.sh phases/update.sh phases/update-dashboard.sh phases/install-initial.sh phases/install-reinstall.sh phases/install-restore.sh phases/install.sh phases/provision-initial.sh phases/provision-reboot.sh phases/provision-migration.sh phases/provision.sh phases/media.sh phases/rig.sh phases/fault.sh phases/reset.sh)
expected_modules="${modules[*]}"
actual_modules="$(sed -n 's|^source "$SCRIPT_DIR/\([a-z/-]*\.sh\)".*|\1|p' "$HERE/run.sh" | tr '\n' ' ' | sed 's/ $//')"
[ "$actual_modules" = "$expected_modules" ] || {
    echo "os module order mismatch: $actual_modules" >&2
    exit 1
}

expected_functions='ok bad info have _ssh _wait_ssh _boot_id _wait_new_boot _reboot_wait _ssh_unreachable_reason _marker _dash_marker_served _wait_dhcp_ip _wait_setup_page _build_image _build_bundle _stage_bundle _install_cmd _commit_cmd _boot_spare_cmd _install_and_boot_cmd _rollback_cmd require_host require_probe_key_matches_image require_clean_bench cleanup wait_serial phase_boot _vm_boot_disk phase_update _wizard_provision_capture _os_step _serve_update_dir _leg4_srv_stop phase_update_dashboard phase_install phase_provision _make_media_stick _attach_media_stick _detach_media_stick _media_stick_has_config phase_media _rig_mining_up phase_rig phase_fault phase_reset'
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
# shellcheck source=tests/os/phases/fault.sh
source "$HERE/phases/fault.sh" || exit $?
# shellcheck source=tests/os/phases/reset.sh
source "$HERE/phases/reset.sh" || exit $?
trap - EXIT
for fn in $expected_functions; do type "$fn" >/dev/null 2>&1 || exit 1; done
for fn in _phase_install_initial _phase_install_reinstall _phase_install_restore _phase_provision_initial _phase_provision_reboot _phase_provision_migration; do type "$fn" >/dev/null 2>&1 || exit 1; done
rm -f "$SERIAL" "$SERIAL.failed"
echo "os-run-modules: PASS"
