# shellcheck shell=bash
: "${OS_RUN_SUITE:?source via the suite runner}"
# shellcheck source=tests/os/phases/install-initial.sh
source "$SCRIPT_DIR/phases/install-initial.sh" || return $?
# shellcheck source=tests/os/phases/install-rig.sh
source "$SCRIPT_DIR/phases/install-rig.sh" || return $?
# shellcheck source=tests/os/phases/install-commit.sh
source "$SCRIPT_DIR/phases/install-commit.sh" || return $?
# shellcheck source=tests/os/phases/install-reinstall.sh
source "$SCRIPT_DIR/phases/install-reinstall.sh" || return $?
# shellcheck source=tests/os/phases/install-fresh-start.sh
source "$SCRIPT_DIR/phases/install-fresh-start.sh" || return $?
# shellcheck source=tests/os/phases/install-restore-preboot.sh
source "$SCRIPT_DIR/phases/install-restore-preboot.sh" || return $?
# shellcheck source=tests/os/phases/install-restore.sh
source "$SCRIPT_DIR/phases/install-restore.sh" || return $?
phase_install() {
    # shellcheck disable=SC2034
    local img target_disk="/srv/code/bench-vm/pithead-target.img" out marker
    # shellcheck disable=SC2034
    local token="" jar="" scode="" tries2=0 body=""
    _phase_install_rig || return
    _phase_install_initial || return
    _phase_install_commit || return
    _phase_install_reinstall || return
    _phase_install_restore
}
