#!/bin/sh
# monero-wallet-rpc health (#381, #718).
#
# RPC-up is the normal signal: a JSON-RPC get_version proves the server is answering. Credentials
# come from the environment, not argv, so `docker inspect` can't read them (#90).
#
# But during the INITIAL payout scan (#718) monero-wallet-rpc is single-threaded and heads-down for
# the whole scan — with the genesis default it is HOURS, and it refuses the RPC the entire time. A
# plain RPC check flaps unhealthy after the 2m start_period and spams stack-health alerts for the
# whole first scan. So: a marker file (`.payout-scanning`, written by the entrypoint on wallet
# creation, living in the volume so it survives recreates) means "still on the first scan" — but
# only for PAYOUT_SCAN_GRACE_SEC (24h by default). The first time the RPC answers, the scan has
# caught up, so we clear the marker and are strict from then on. A marker that outlives the grace,
# or a later RPC failure, is a real fault rather than scan tolerance.
set -u

WALLET_DIR="${WALLET_DIR:-/home/ubuntu/wallets}"
SCAN_MARKER="$WALLET_DIR/.payout-scanning"
PAYOUT_SCAN_GRACE_SEC="${PAYOUT_SCAN_GRACE_SEC:-86400}"

rpc_up() {
    curl -fsS --digest \
        -u "${WALLET_RPC_USERNAME:-wallet}:${WALLET_RPC_PASSWORD:-}" \
        -o /dev/null \
        -H 'Content-Type: application/json' \
        -d '{"jsonrpc":"2.0","id":"0","method":"get_version"}' \
        http://localhost:18082/json_rpc
}

scan_grace_active() {
    marker_mtime="$(stat -c %Y "$SCAN_MARKER" 2>/dev/null || stat -f %m "$SCAN_MARKER")" || return 1
    now="$(date +%s)" || return 1
    case "$PAYOUT_SCAN_GRACE_SEC:$marker_mtime:$now" in *[!0-9:]* | *::* | :* | *:) return 1 ;; esac
    [ "$now" -ge "$marker_mtime" ] && [ $((now - marker_mtime)) -lt "$PAYOUT_SCAN_GRACE_SEC" ]
}

if rpc_up; then
    # Caught up and answering — retire the initial-scan grace so future RPC failures read as real.
    rm -f "$SCAN_MARKER" 2>/dev/null || true
    exit 0
fi

# RPC silent. Healthy only for a bounded first scan; else it's a fault.
[ -f "$SCAN_MARKER" ] && scan_grace_active && exit 0
exit 1
