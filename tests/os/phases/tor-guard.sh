# shellcheck shell=bash
: "${OS_RUN_SUITE:?source via the suite runner}"
# shellcheck source=tests/os/lib/redact-addr.sh
source "${BASH_SOURCE[0]%/*}/../lib/redact-addr.sh"
phase_tor_guard() {
    # shellcheck disable=SC2034
    local img token="" jar="" scode="" marker="" tries=0 code="" pv_user="" pv_pass="" PROVISION_DASHBOARD_HOST=fixture-box rc=0 OS_RESERVED_NODE_CONSUMER=0
    _phase_provision_initial || {
        bad "tor-guard: local-node guest provisioning failed before fault injection"
        return 1
    }
    SSH_TIMEOUT=12800 _ssh 'timeout 12500 bash -s' <"$SCRIPT_DIR/tor-guard-guest.sh" || rc=$?
    if [ "$rc" = 0 ]; then
        ok "guest Tor stalled by refused circuit creates is cured by guard rotation without a restart (#4342)"
    else
        printf 'Guest stderr: %s\n' "$(tr -d '\r' <"$SSH_ERR" 2>/dev/null | os_redact_addr | tail -c 4096)"
        bad "guest Tor guard-rotation leg failed: fault not reproduced or rotation did not cure it (#4342)"
    fi
}
