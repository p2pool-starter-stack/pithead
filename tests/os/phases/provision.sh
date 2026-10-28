# shellcheck shell=bash
: "${OS_RUN_SUITE:?source via the suite runner}"
# shellcheck source=tests/os/phases/provision-initial.sh
source "$SCRIPT_DIR/phases/provision-initial.sh" || return $?
# shellcheck source=tests/os/phases/provision-reboot.sh
source "$SCRIPT_DIR/phases/provision-reboot.sh" || return $?
# shellcheck source=tests/os/phases/provision-power-cut.sh
source "$SCRIPT_DIR/phases/provision-power-cut.sh" || return $?
# shellcheck source=tests/os/phases/provision-migration.sh
source "$SCRIPT_DIR/phases/provision-migration.sh" || return $?
phase_provision() {
    # The sourced legs use these locals through Bash's dynamic function scope.
    # shellcheck disable=SC2034
    local img token="" jar="" scode="" marker="" tries=0 code=""
    # pv_user/pv_pass are set by the initial leg and read by the reboot and migration legs,
    # so they belong to the phase, not to one leg.
    local pv_user="" pv_pass=""
    # shellcheck disable=SC2034 # provision_browser_config reads both through dynamic scope.
    local PROVISION_DASHBOARD_HOST=fixture-box
    _phase_provision_initial || return
    _phase_provision_reboot || return
    _phase_provision_power_cut || return
    _phase_provision_migration
}

_provision_chain_directory_move() {
    local out rc=0
    out=$(mktemp)
    SSH_TIMEOUT=600 _ssh 'cd /data/pithead && TMPDIR=/data bash -s' <"$SCRIPT_DIR/../integration/chain-directory-move.sh" >"$out" 2>&1 || rc=$?
    if [ "$rc" = 0 ] && grep -Fq 'chain directory move: both container IDs and start times preserved' "$out"; then
        ok "chain directory move preserves both container IDs and start times"
    else
        bad "chain directory move did not preserve node identity (exit $rc)"
        tail -n 25 "$out"
        rm -f "$out"
        return 1
    fi
    rm -f "$out"
}
