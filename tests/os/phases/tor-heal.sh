# shellcheck shell=bash
: "${OS_RUN_SUITE:?source via the suite runner}"
phase_tor_heal() {
    # Provision the normal local-node appliance: recovery verifies local Monero peers.
    # These locals are shared with the existing initial-provision fixture through dynamic scope.
    # shellcheck disable=SC2034
    local img token="" jar="" scode="" marker="" tries=0 code="" pv_user="" pv_pass="" PROVISION_DASHBOARD_HOST=fixture-box
    _phase_provision_initial || {
        bad "tor-heal: local-node guest provisioning failed before fault injection"
        return 1
    }
    # The script is streamed only into this job's guest; normal 15/30-minute timers are retained.
    if SSH_TIMEOUT=13000 _ssh 'timeout 12500 bash -s' <"$SCRIPT_DIR/tor-heal-guest.sh"; then
        ok "guest Tor saturated-history self-heal and disabled control (#3118)"
    else
        # _ssh sends guest stderr, which carries the failing stage, to $SSH_ERR; surface it.
        printf 'Guest stderr: %s\n' "$(tail -c 2048 "$SSH_ERR" 2>/dev/null | tr -d '\r')"
        bad "guest Tor saturated-history self-heal or disabled control failed (#3118)"
    fi
}
