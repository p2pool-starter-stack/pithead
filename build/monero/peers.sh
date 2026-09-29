#!/bin/sh
# monerod's real peer counts, read from the admin RPC bound to this container's own loopback (#2921).
#
# The published RPC is restricted, and a restricted get_info answers 0 for the connection counts and
# peer-list sizes (upstream core_rpc_server.cpp), so a zero from it is not a reading. This helper only
# ever talks to the unpublished loopback listener, takes its login from the container's environment (never
# argv or output), and prints ONE line of counts, nothing else:
#   {"outgoing":N,"incoming":N,"white":N,"grey":N}
# It exits non-zero and prints nothing when the listener does not answer, when the body does not say
# `"restricted": false` (a restricted answer must never be read as counts), or when a count is missing.
set -eu

port=${MONERO_ADMIN_RPC_PORT:-18085}
body=$(curl -fsS --max-time 2 --max-filesize 65536 --digest \
    -u "${MONERO_NODE_USERNAME:-}:${MONERO_NODE_PASSWORD:-}" \
    "http://127.0.0.1:$port/get_info") || exit 1

printf '%s' "$body" | grep -q '"restricted": *false' || exit 3

field() { printf '%s' "$body" | sed -n "s/.*\"$1\": *\([0-9][0-9]*\).*/\1/p" | head -n 1; }
out=$(field outgoing_connections_count)
inn=$(field incoming_connections_count)
white=$(field white_peerlist_size)
grey=$(field grey_peerlist_size)
[ -n "$out" ] && [ -n "$inn" ] && [ -n "$white" ] && [ -n "$grey" ] || exit 4
printf '{"outgoing":%s,"incoming":%s,"white":%s,"grey":%s}\n' "$out" "$inn" "$white" "$grey"
