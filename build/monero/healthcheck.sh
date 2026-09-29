#!/bin/sh
# monerod RPC liveness check (#90).
#
# Reads the RPC credentials from the container's environment instead of taking them as
# arguments, so they are NOT baked into the compose `healthcheck.test` — where they would
# otherwise be readable via `docker inspect`. monerod serves RPC on localhost:18081 and requires
# digest auth when MONERO_NODE_USERNAME/MONERO_NODE_PASSWORD are set.
#
# Also fails a node with no outgoing peers for MONERO_HEALTH_PEERLESS_SEC (#2499): the RPC answers
# and `synchronized` stays true on an isolated node, so liveness alone reads green. The peer count
# comes from the get_info body already fetched; the first zero reading is stamped in /tmp (tmpfs)
# and any peer clears it. A body without the count (an older monerod) is never a failure.
set -eu

stamp=${MONERO_HEALTH_STAMP:-/tmp/monerod-peerless-since}
# An RPC that does not answer is unhealthy on its own, and ends any zero-peer stretch: the next
# zero reading starts a fresh bound instead of inheriting a stamp from before a restart.
body=$(curl -fsS --digest \
    -u "${MONERO_NODE_USERNAME:-}:${MONERO_NODE_PASSWORD:-}" \
    http://localhost:18081/get_info) || {
    rm -f "$stamp"
    exit 1
}

out=$(printf '%s' "$body" | sed -n 's/.*"outgoing_connections_count": *\([0-9][0-9]*\).*/\1/p' | head -n 1)
if [ -z "$out" ] || [ "$out" -gt 0 ]; then
    rm -f "$stamp"
    exit 0
fi
now=$(date +%s)
[ -s "$stamp" ] || echo "$now" >"$stamp"
since=$(cat "$stamp")
if [ $((now - since)) -ge "${MONERO_HEALTH_PEERLESS_SEC:-600}" ]; then
    echo "monerod has had 0 outgoing peers for $(((now - since) / 60)) min" >&2
    exit 1
fi
