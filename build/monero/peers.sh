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

body=$(printf 'user = %s\n' "$(printf '%s:%s' "${MONERO_NODE_USERNAME:-}" "${MONERO_NODE_PASSWORD:-}" | jq -Rs .)" |
    curl -fsS --max-time 2 --max-filesize 65536 --digest --config - \
        http://127.0.0.1:18085/get_info) || exit 1

printf '%s' "$body" | jq -ec '
    def count: type == "number" and . >= 0 and . == floor;
    if .restricted != false then empty
    elif ([.outgoing_connections_count, .incoming_connections_count,
           .white_peerlist_size, .grey_peerlist_size] | all(count)) then
        {outgoing: .outgoing_connections_count, incoming: .incoming_connections_count,
         white: .white_peerlist_size, grey: .grey_peerlist_size}
    else empty end
' || exit 3
