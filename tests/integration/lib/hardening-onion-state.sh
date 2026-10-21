# shellcheck shell=bash
: "${INTEGRATION_RUN_SUITE:?source via the suite runner}"
HARDENING_ONION_SNAPSHOT=""
HARDENING_ONION_RESTORING=0

hardening_onion_snapshot() {
    [ -z "$HARDENING_ONION_SNAPSHOT" ] || return 1
    HARDENING_ONION_SNAPSHOT="$(rx "sudo -n python3 tests/integration/lib/hardening_onion_state.py save $(quote_arg "$(env_on_box TOR_DATA_DIR)")" 2>/dev/null)" || return 1
    [ -n "$HARDENING_ONION_SNAPSHOT" ] || return 1
    if [ "${_SAFETY_RESTORE_ARMED:-0}" != 1 ]; then arm_safety_abort_restore; fi
}

hardening_onion_restore() {
    [ -n "$HARDENING_ONION_SNAPSHOT" ] || return 0
    [ "$HARDENING_ONION_RESTORING" = 0 ] || return 1
    HARDENING_ONION_RESTORING=1
    local helper="sudo -n python3 tests/integration/lib/hardening_onion_state.py" snapshot step=restore
    snapshot="$(quote_arg "$HARDENING_ONION_SNAPSHOT")"
    if rx "$helper restore $snapshot" >/dev/null 2>&1 &&
        step=config && push_config "$BASELINE_CONFIG" &&
        step=apply && pithead apply -y >/dev/null 2>&1 &&
        step=health && wait_status_ok 240 &&
        step=verify && rx "$helper verify $snapshot" >/dev/null &&
        step=units && _remove_control_units &&
        step=cleanup && rx "$helper cleanup $snapshot" >/dev/null 2>&1; then
        HARDENING_ONION_SNAPSHOT=""
        HARDENING_ONION_RESTORING=0
        return 0
    fi
    it_step "hardening onion restore failed at $step; protected recovery copies retained"
    HARDENING_ONION_RESTORING=0
    return 1
}
