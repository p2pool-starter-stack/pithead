#!/bin/sh
# monerod RPC liveness check (#90).
#
# Reads the RPC credentials from the container's environment instead of taking them as
# arguments, so they are NOT baked into the compose `healthcheck.test` — where they would
# otherwise be readable via `docker inspect`. monerod serves RPC on localhost:18081 and requires
# digest auth when MONERO_NODE_USERNAME/MONERO_NODE_PASSWORD are set.
#
# Also fails a node with no outgoing peers for MONERO_HEALTH_PEERLESS_SEC (#2499): the RPC answers
# and `synchronized` stays true on an isolated node, so liveness alone reads green. The liveness call
# is the published, restricted listener; the peer counts are NOT read from it, because a restricted
# get_info answers 0 for them (#2921). They come from monerod-peers.sh, which reads the admin listener
# on this container's loopback. The first real zero is stamped in /tmp (tmpfs) and any peer clears it.
# A helper that gives no reading (listener down, restricted body, missing count) is "unavailable": no
# stamp or fabricated zero, and the healthcheck fails until visibility returns. Every run prints one bounded line, which docker keeps in
# State.Health.Log for the dashboard: `pithead-monero-peers {"outgoing":N,...}` or
# `pithead-monero-peers unavailable`. No credential or raw response is printed.
set -eu

stamp=${MONERO_HEALTH_STAMP:-/tmp/monerod-peerless-since}
# An RPC that does not answer is unhealthy on its own, and ends any zero-peer stretch: the next
# zero reading starts a fresh bound instead of inheriting a stamp from before a restart.
curl -fsS --max-time 2 --digest \
    -u "${MONERO_NODE_USERNAME:-}:${MONERO_NODE_PASSWORD:-}" \
    http://localhost:18081/get_info >/dev/null || {
    rm -f "$stamp"
    exit 1
}

peers=$("${MONERO_PEERS_HELPER:-/usr/local/bin/monerod-peers.sh}" 2>/dev/null) || peers=
out=$(printf '%s' "$peers" | sed -n 's/.*"outgoing": *\([0-9][0-9]*\).*/\1/p' | head -n 1)
if [ -z "$out" ]; then
    echo "pithead-monero-peers unavailable"
    rm -f "$stamp"
    exit 1
fi
echo "pithead-monero-peers $peers"
if [ "$out" -gt 0 ]; then
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
