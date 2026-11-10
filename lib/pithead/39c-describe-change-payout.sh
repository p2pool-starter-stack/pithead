payout_scan_target() {
    local host="${MONERO_REMOTE_HOST:-}"
    [ "${PAYOUT_NODE_REMOTE:-false}" = true ] || {
        printf 'the local Monero node'
        return
    }
    case "$host" in *:*) host="[$host]" ;; esac
    if [ -n "${PAYOUT_NODE_PROXY:-}" ]; then
        printf 'the remote Monero node %s:%s through Tor' "$host" "$MONERO_REMOTE_RPC_PORT"
    else
        printf 'the remote Monero node %s:%s directly, not through Tor' "$host" "$MONERO_REMOTE_RPC_PORT"
    fi
}

describe_payout_change() {
    case "$1" in
    MONERO_VIEW_KEY)
        if [ -z "$3" ]; then
            msg="Payout confirmation view key CLEARED — the view-only wallet-rpc is removed."
        elif [ -z "$2" ]; then
            flag=DEST
            msg="Payout confirmation view key SET — a view-only monero-wallet-rpc starts and scans for confirmed payouts through $(payout_scan_target) (it can see incoming amounts, never spend)."
        else
            flag=DEST
            msg="Payout confirmation view key CHANGED — a new view-only wallet is opened for this address (the previous one is kept). It scans through $(payout_scan_target)."
        fi
        ;;
    PAYOUT_NODE_REMOTE)
        if [ "$3" = true ]; then
            flag=CONFIRM
            msg="Payout scans now use $(payout_scan_target). That node's operator sees the wallet's scan requests and timing, and can hide or misreport payouts."
        else
            msg="Payout scans return to the local Monero node."
        fi
        ;;
    PAYOUT_NODE_PROXY)
        msg=""
        if [ "${PAYOUT_NODE_REMOTE:-false}" = true ]; then
            if [ -n "$3" ]; then msg="Payout scans reach the remote node through Tor."; else msg="Payout scans reach the remote node directly; its operator sees this host's IP address."; fi
        fi
        ;;
    *) return 1 ;;
    esac
}
