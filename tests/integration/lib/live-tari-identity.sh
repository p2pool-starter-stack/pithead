#!/usr/bin/env bash
# shellcheck disable=SC2034 # both read by live-gates.sh
tari_error_summary() {
    grep -E 'status = |details = |Error|StopIteration|error' | tr '\n\t' '  ' | tr -s ' ' |
        sed -E 's/ipv[46]:[^ ,"]*/<addr>/g; s/name=[^ ,"]*/name=<host>/g; s/[A-Za-z0-9._[-]+\]?:[0-9]{2,5}/<addr>/g; s/[0-9]+(\.[0-9]+){3}/<addr>/g' | sed -E 's/ +$//' | cut -c1-300
}

TARI_IDENTITY="" TARI_IDENTITY_ERROR=""
tari_block_identity_checked() { # <height>
    local out identity summary attempt=0 attempts=3
    TARI_IDENTITY="" TARI_IDENTITY_ERROR=""
    while [ "$attempt" -lt "$attempts" ]; do
        attempt=$((attempt + 1))
        out="$(tari_identity_remote "$1" || true)"
        identity="$(printf '%s\n' "$out" | grep -E '^[0-9]+ [0-9a-f]{64}$' | head -n 1 || true)"
        if [ -n "$identity" ]; then
            TARI_IDENTITY="$identity"
            return 0
        fi
        summary="$(printf '%s\n' "$out" | tari_error_summary || true)"
        TARI_IDENTITY_ERROR="attempt $attempt/$attempts: ${summary:-no output}"
        [ "$attempt" -ge "$attempts" ] || sleep 5
    done
    return 1
}

tari_block_identity() { # <height>
    tari_identity_remote "$1" | grep -E '^[0-9]+ [0-9a-f]{64}$' || true
}

tari_identity_remote() { # <height>
    rx "docker exec dashboard python3 -c 'import grpc,sys;from mining_dashboard.config.config import TARI_GRPC_ADDRESS;from mining_dashboard.client.tari.generated import base_node_pb2,base_node_pb2_grpc;s=base_node_pb2_grpc.BaseNodeStub(grpc.insecure_channel(TARI_GRPC_ADDRESS));h=next(s.ListHeaders(base_node_pb2.ListHeadersRequest(from_height=int(sys.argv[1]),num_headers=1,sorting=base_node_pb2.SORTING_ASC),timeout=8)).header;print(h.height,h.hash.hex())' $(quote_arg "$1")" 2>&1
}

chain_identity_failure_detail() { # <monero-id> <tari-id> <tari-height>
    local unreadable=""
    [ -n "$1" ] || unreadable+=" Monero tip hash (get_info returned none)"
    [ -n "$2" ] || unreadable+=" Tari block at height $3 (ListHeaders: ${TARI_IDENTITY_ERROR:-no output})"
    printf 'could not read:%s; upgrade not attempted' "$unreadable"
}
