# shellcheck shell=bash
: "${OS_RUN_SUITE:?source via the suite runner}"
phase_tor_heal_exhausted() {
    # shellcheck disable=SC2034
    local img token="" jar="" scode="" marker="" tries=0 code="" pv_user="" pv_pass="" PROVISION_DASHBOARD_HOST=fixture-box OS_RESERVED_NODE_CONSUMER=0
    _phase_provision_initial || {
        bad "tor-heal-exhausted: local-node guest provisioning failed before fault injection"
        return 1
    }
    if SSH_TIMEOUT=7000 _ssh 'timeout 6500 bash -s' <"$SCRIPT_DIR/tor-heal-exhausted-guest.sh"; then
        ok "guest Tor self-heal resets state after a rejected NEWNYM without a saturated history (#4075)"
    else
        printf 'Guest stderr: %s\n' "$(tail -c 2048 "$SSH_ERR" 2>/dev/null | tr -d '\r')"
        bad "guest Tor self-heal after a rejected NEWNYM failed (#4075)"
    fi
}
