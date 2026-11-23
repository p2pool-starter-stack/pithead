# shellcheck shell=bash
: "${OS_RUN_SUITE:?source via the suite runner}"
# shellcheck source=tests/os/lib/redact-addr.sh
source "${BASH_SOURCE[0]%/*}/../lib/redact-addr.sh"
phase_monerod_redial() {
    # shellcheck disable=SC2034
    local img token="" jar="" scode="" marker="" tries=0 code="" pv_user="" pv_pass="" PROVISION_DASHBOARD_HOST=fixture-box rc=0 OS_RESERVED_NODE_CONSUMER=0
    _phase_provision_initial || {
        bad "monerod-redial: local-node guest provisioning failed before fault injection"
        return 1
    }
    SSH_TIMEOUT=12800 _ssh 'timeout 12500 bash -s' <"$SCRIPT_DIR/monerod-redial-guest.sh" || rc=$?
    case "$rc" in
    0) ok "guest monerod is re-dialled or restarted within bounds after a Tor restart and a peerless strand (#4157)" ;;
    77) it_skip_leg "monerod-redial: monerod running with outgoing peers (#4157)" "the guest monerod never had outgoing peers" missing ;;
    *)
        printf 'Guest stderr: %s\n' "$(tr -d '\r' <"$SSH_ERR" 2>/dev/null | os_redact_addr | tail -c 2048)"
        bad "guest monerod re-dial, peerless restart, cooldown, daily cap or safety failed (#4157)"
        ;;
    esac
}
