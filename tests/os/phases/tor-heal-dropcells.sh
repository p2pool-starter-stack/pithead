# shellcheck shell=bash
: "${OS_RUN_SUITE:?source via the suite runner}"
phase_tor_heal_dropcells() {
    # shellcheck disable=SC2034
    local img token="" jar="" scode="" marker="" tries=0 code="" pv_user="" pv_pass="" PROVISION_DASHBOARD_HOST=fixture-box OS_RESERVED_NODE_CONSUMER=0
    _phase_provision_initial || {
        bad "tor-heal-dropcells: local-node guest provisioning failed before fault injection"
        return 1
    }
    if SSH_TIMEOUT=12500 _ssh 'timeout 12000 bash -s' <"$SCRIPT_DIR/tor-heal-dropcells-guest.sh"; then
        ok "guest Tor self-heal keeps its disruptive-rung spacing while circuit creation is dropped on an open channel (#4280)"
    else
        printf 'Guest stderr: %s\n' "$(tail -c 2048 "$SSH_ERR" 2>/dev/null | tr -d '\r')"
        bad "guest Tor self-heal with circuit creation dropped on an open channel failed (#4280)"
    fi
}
