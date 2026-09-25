#!/bin/sh
# monero-wallet-rpc health (#381, #718).
#
# RPC-up is the normal signal: a JSON-RPC get_version proves the server is answering. Credentials
# come from the environment, not argv, so `docker inspect` can't read them (#90).
#
# But during the INITIAL payout scan (#718) monero-wallet-rpc is single-threaded and heads-down for
# the whole scan — with the genesis default it is HOURS, and it refuses the RPC the entire time. A
# plain RPC check flaps unhealthy after the 2m start_period and spams stack-health alerts for the
# whole first scan. So: a marker file (`.payout-scanning`, written by the entrypoint on every start,
# since a reopened wallet also scans the blocks it missed (#2720), living in the volume so it
# survives recreates) means "still scanning" — but only for PAYOUT_SCAN_GRACE_SEC (24h by default).
# The RPC answers between refresh passes, so an answer alone does not mean caught up: the marker is
# cleared only once the wallet height reaches monerod's block count (or monerod's count is
# unreadable), and we are strict from then on. A marker that outlives the grace, or a later RPC
# failure, is a real fault rather than scan tolerance.
set -u

WALLET_DIR="${WALLET_DIR:-/home/ubuntu/wallets}"
SCAN_MARKER="$WALLET_DIR/.payout-scanning"
PAYOUT_SCAN_GRACE_SEC="${PAYOUT_SCAN_GRACE_SEC:-86400}"

# $1 = JSON-RPC method, $2 = curl --max-time; prints the response body. The three calls below stay
# inside compose's 5s healthcheck timeout.
wallet_rpc() {
    curl -fsS --digest --max-time "$2" \
        -u "${WALLET_RPC_USERNAME:-wallet}:${WALLET_RPC_PASSWORD:-}" \
        -H 'Content-Type: application/json' \
        -d "{\"jsonrpc\":\"2.0\",\"id\":\"0\",\"method\":\"$1\"}" \
        http://localhost:18082/json_rpc
}

daemon_block_count() {
    curl -fsS --digest --max-time 1 \
        -u "${MONERO_NODE_USERNAME:-}:${MONERO_NODE_PASSWORD:-}" \
        -H 'Content-Type: application/json' \
        -d '{"jsonrpc":"2.0","id":"0","method":"get_block_count"}' \
        "http://${MONERO_NODE_HOST:-127.0.0.1}:${MONERO_RPC_PORT:-18081}/json_rpc"
}

# $1 = JSON field; prints its first integer value from stdin, or nothing.
json_int() {
    tr -d ' \n' | sed -n "s/.*\"$1\":\([0-9][0-9]*\).*/\1/p"
}

# The wallet has scanned to the daemon's tip (a couple of blocks' slack for a block landing between
# the two reads). An unreadable daemon count counts as caught up: strict is the safe default.
caught_up() {
    daemon_h="$(daemon_block_count 2>/dev/null | json_int count)"
    [ -n "$daemon_h" ] || return 0
    wallet_h="$(wallet_rpc get_height 1 2>/dev/null | json_int height)"
    [ -n "$wallet_h" ] && [ $((wallet_h + 2)) -ge "$daemon_h" ]
}

scan_grace_active() {
    marker_mtime="$(stat -c %Y "$SCAN_MARKER" 2>/dev/null || stat -f %m "$SCAN_MARKER")" || return 1
    now="$(date +%s)" || return 1
    case "$PAYOUT_SCAN_GRACE_SEC:$marker_mtime:$now" in *[!0-9:]* | *::* | :* | *:) return 1 ;; esac
    [ "$now" -ge "$marker_mtime" ] && [ $((now - marker_mtime)) -lt "$PAYOUT_SCAN_GRACE_SEC" ]
}

if wallet_rpc get_version 3 >/dev/null; then
    # Answering and caught up: retire the scan grace so future RPC failures read as real.
    [ -f "$SCAN_MARKER" ] && caught_up && { rm -f "$SCAN_MARKER" 2>/dev/null || true; }
    exit 0
fi

# RPC silent. Healthy only for a bounded first scan; else it's a fault.
[ -f "$SCAN_MARKER" ] && scan_grace_active && exit 0
exit 1
