# shellcheck shell=bash
: "${OS_RUN_SUITE:?source via the suite runner}"
# shellcheck source=tests/os/lib/redact-addr.sh
source "${BASH_SOURCE[0]%/*}/../lib/redact-addr.sh"
phase_p2pool_heal() {
    # shellcheck disable=SC2034
    local img token="" jar="" scode="" marker="" tries=0 code="" pv_user="" pv_pass="" PROVISION_DASHBOARD_HOST=fixture-box rc=0 OS_RESERVED_NODE_CONSUMER=0
    _phase_provision_initial || {
        bad "p2pool-heal: guest provisioning failed before observation"
        return 1
    }
    SSH_TIMEOUT=6000 _ssh 'timeout 5800 bash -s' <"$SCRIPT_DIR/pool-heal-guest.sh" || rc=$?
    case "$rc" in
    0) ok "guest P2Pool is restarted by the dashboard healer (#4077)" ;;
    77) it_skip_leg "p2pool-heal: observe a peerless guest P2Pool (#4077)" "the guest skipped" missing ;;
    *)
        printf 'Guest stderr: %s\n' "$(tr -d '\r' <"$SSH_ERR" 2>/dev/null | os_redact_addr | tail -c 2048)"
        bad "guest P2Pool peer-loss restart, backoff or cap failed (#4077)"
        ;;
    esac
}
