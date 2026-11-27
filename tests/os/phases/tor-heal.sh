# shellcheck shell=bash
: "${OS_RUN_SUITE:?source via the suite runner}"
# shellcheck source=tests/os/lib/redact-addr.sh
source "${BASH_SOURCE[0]%/*}/../lib/redact-addr.sh"
phase_tor_heal() {
    # shellcheck disable=SC2034
    local img token="" jar="" scode="" marker="" tries=0 code="" pv_user="" pv_pass="" PROVISION_DASHBOARD_HOST=fixture-box OS_RESERVED_NODE_CONSUMER=0
    _phase_provision_initial || {
        bad "tor-heal: local-node guest provisioning failed before fault injection"
        return 1
    }
    # The script is streamed only into this job's guest; normal 15/30-minute timers are retained.
    if SSH_TIMEOUT=13000 _ssh 'timeout 12500 bash -s' <"$SCRIPT_DIR/tor-heal-guest.sh"; then
        ok "guest No login Tor egress self-heal and disabled control (#3118, #3166)"
    else
        # _ssh sends guest stderr, which carries the failing stage, to $SSH_ERR; surface it.
        printf 'Guest stderr: %s\n' "$(tr -d '\r' <"$SSH_ERR" 2>/dev/null | os_redact_addr | tail -c 2048)"
        bad "guest No login Tor egress self-heal or disabled control failed (#3118, #3166)"
    fi
}
