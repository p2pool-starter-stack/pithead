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
    local helper="sudo -n python3 tests/integration/lib/hardening_onion_state.py" snapshot
    snapshot="$(quote_arg "$HARDENING_ONION_SNAPSHOT")"
    if rx "$helper restore $snapshot" >/dev/null 2>&1 &&
        push_config "$BASELINE_CONFIG" && pithead apply -y >/dev/null 2>&1 && wait_status_ok 240 &&
        rx "$helper verify $snapshot" >/dev/null 2>&1 && _remove_control_units &&
        rx "$helper cleanup $snapshot" >/dev/null 2>&1; then
        HARDENING_ONION_SNAPSHOT=""
        HARDENING_ONION_RESTORING=0
        return 0
    fi
    HARDENING_ONION_RESTORING=0
    return 1
}
