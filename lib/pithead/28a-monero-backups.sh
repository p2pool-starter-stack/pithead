validate_monero_backups() {
    local reason entry host index=0 primary
    reason=$(jq -r '
        def port: type == "number" and . == floor and . >= 1 and . <= 65535;
        if (.monero | has("backup_nodes")) and (.monero.backup_nodes | type) != "array"
        then "monero.backup_nodes must be an array."
        else (.monero.backup_nodes // [] | to_entries[]
            | "monero.backup_nodes[\(.key)]" as $p | .value
            | if type != "object" then "\($p) must be an object."
              elif (keys - ["host", "rpc_port", "zmq_port", "rpc_login"] | length) > 0
              then "\($p) has an unknown key."
              elif (.host | type) != "string" then "\($p).host must be a hostname or IP literal."
              elif (.rpc_port | port | not) then "\($p).rpc_port must be an integer TCP port 1–65535."
              elif (.zmq_port | port | not) then "\($p).zmq_port must be an integer TCP port 1–65535."
              elif has("rpc_login") and ((.rpc_login | type) != "string")
              then "\($p).rpc_login must be a string."
              else empty end) end' "$CONFIG_FILE") || error "Cannot validate monero.backup_nodes."
    [ -z "$reason" ] || error "$reason"
    primary="$NETWORK_PREFIX.26"
    [ "$MONERO_MODE" != remote ] || primary="$MONERO_REMOTE_HOST"
    reason=$(jq -r --arg host "$primary" --argjson rpc "${MONERO_REMOTE_RPC_PORT:-18081}" --argjson zmq "${MONERO_REMOTE_ZMQ_PORT:-18083}" '
        reduce (.monero.backup_nodes // [] | to_entries[]) as $e
            ({seen: [[$host | ascii_downcase, $rpc, $zmq]], error: ""};
             [$e.value.host | ascii_downcase, $e.value.rpc_port, $e.value.zmq_port] as $key
             | if any(.seen[]; . == $key) then .error = "monero.backup_nodes[\($e.key)] duplicates a configured node."
               else .seen += [$key] end) | .error' "$CONFIG_FILE") || error "Cannot compare monero.backup_nodes."
    [ -z "$reason" ] || error "$reason"
    while IFS= read -r entry; do
        host=$(jq -r .host <<<"$entry")
        is_valid_host "$host" || error "monero.backup_nodes[$index].host must be a hostname or IP literal."
        index=$((index + 1))
    done < <(jq -c '.monero.backup_nodes // [] | .[]' "$CONFIG_FILE")
    reason=$(monero_backup_addresses_allowed "$CONFIG_FILE") || error "$reason"
    [ "${PITHEAD_DRY_RUN:-0}" = 1 ] || preflight_monero_backups "$CONFIG_FILE"
}

monero_backup_args() {
    jq -r '.monero.backup_nodes // [] | .[] |
        ("--host", .host, "--rpc-port", (.rpc_port | tostring), "--zmq-port", (.zmq_port | tostring),
         (if (.rpc_login // "") == "" then empty else "--rpc-login", .rpc_login end)) | @base64' "$CONFIG_FILE" | paste -sd ' ' -
}

monero_backup_addresses_allowed() {
    local cfg="$1" entry host port index=0 rc
    while IFS= read -r entry; do
        host=$(jq -r .host <<<"$entry")
        port=$(jq -r .rpc_port <<<"$entry")
        rc=0
        remote_node_address "$cfg" "$host" >/dev/null || rc=$?
        if [ "$rc" -eq 2 ]; then
            printf 'monero.backup_nodes[%s]: the remote Monero node name %s does not resolve from this machine — check it for a typo, or give a numeric address' "$index" "$host"
            return 1
        fi
        if [ "$rc" -ne 0 ]; then
            printf 'monero.backup_nodes[%s]: cannot use the remote Monero node at %s:%s — use an address allowed by network.tor_egress_firewall' "$index" "$host" "$port"
            return 1
        fi
        index=$((index + 1))
    done < <(jq -c '.monero.backup_nodes // [] | .[]' "$cfg")
}

preflight_monero_backups() {
    local cfg="$1" entry host address rpc zmq login index=0 reason
    while IFS= read -r entry; do
        host=$(jq -r .host <<<"$entry")
        rpc=$(jq -r .rpc_port <<<"$entry")
        zmq=$(jq -r .zmq_port <<<"$entry")
        login=$(jq -r '.rpc_login // ""' <<<"$entry")
        reason=""
        address=$(remote_node_address "$cfg" "$host") || reason=address
        if [ -z "$reason" ]; then
            monero_rpc_speaks "$cfg" "$address" "$rpc" "$login" || reason="$NODE_PROBE_REASON"
        fi
        if [ -z "$reason" ]; then
            zmq_endpoint_is_publisher "$address" "$zmq" || reason="$NODE_PROBE_REASON"
        fi
        [ -z "$reason" ] || warn "monero.backup_nodes[$index] is unavailable ($reason); continuing with the other nodes."
        index=$((index + 1))
    done < <(jq -c '.monero.backup_nodes // [] | .[]' "$cfg")
    return 0
}
