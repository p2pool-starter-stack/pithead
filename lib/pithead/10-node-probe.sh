#!/usr/bin/env bash
# Host-side remote-node checks shared by first boot and dashboard config commits.

NODE_PROBE_REASON=""

remote_node_ip_allowed() { # <ip> <firewall-enabled>
    local ip="$1" firewall="$2" a b
    if _is_canonical_ipv4 "$ip"; then
        _ipv4_is_sensitive "$ip" && return 1
        IFS=. read -r a b _ _ <<<"$ip"
        [ "$firewall" = false ] && return 0
        case "$a.$b" in
        10.* | 192.168) return 0 ;;
        172.*) [ "$b" -ge 16 ] && [ "$b" -le 31 ] ;;
        100.*) [ "$b" -ge 64 ] && [ "$b" -le 127 ] ;;
        *) return 1 ;;
        esac
        return
    fi
    _is_ipv6_literal "$ip" || return 1
    _ipv6_is_sensitive "$ip" && return 1
    [ "$firewall" = false ] || return 1
    case "${ip,,}" in 2*:* | 3*:* | fc*:* | fd*:*) return 0 ;; *) return 1 ;; esac
}

# Prints one address approved for every probe. Two failures, two exit codes, because the caller has
# to tell them apart and cannot read a variable back out of a command substitution (#1913): rc 2 is
# "the name produced no address at all", rc 1 is "it resolved, and an answer is outside what
# network.tor_egress_firewall allows". Collapsing them sent an operator with a typo'd hostname to
# check a firewall that was working.
remote_node_address() { # <config-file> <host>; rc 2 = unresolvable, rc 1 = address not allowed
    local cfg="$1" host="$2" firewall resolved ip first=""
    firewall=$(config_bool '.network.tor_egress_firewall' true "$cfg")
    resolved=$(_resolve_host_ips "$host") || return 2
    [ -n "$resolved" ] || return 2
    while IFS= read -r ip; do
        remote_node_ip_allowed "$ip" "$firewall" || return 1
        [ -n "$first" ] || first="$ip"
    done <<<"$resolved"
    [ -n "$first" ] && printf '%s' "$first"
}

zmq_greeting_ok() { # <hex>; rc 0 only for a well-formed ZMTP >=3 greeting
    local g="${1,,}" tail
    tail=${g:64}
    [ "${#g}" -eq 128 ] && [ "${g:0:2}" = ff ] && [ "${g:18:2}" = 7f ] &&
        [ "$((16#${g:20:2}))" -ge 3 ] && [ "${g:24:40}" = 4e554c4c00000000000000000000000000000000 ] && [ "$tail" = "${tail//[!0]/}" ]
}

zmq_ready_is_publisher() { # <short command-frame hex>
    local h="${1,,}" size body p=6 n key v val
    [ "${#h}" -ge 4 ] && [ "$((16#${h:0:2} & 6))" -eq 4 ] || return 1
    size=$((16#${h:2:2}))
    [ "$size" -le 64 ] && [ "${#h}" -eq $(((size + 2) * 2)) ] || return 1
    body=${h:4}
    [ "${body:0:12}" = 055245414459 ] || return 1
    while [ "$p" -lt "$size" ]; do
        [ "$((p + 1))" -le "$size" ] || return 1
        n=$((16#${body:$((p * 2)):2}))
        p=$((p + 1))
        [ "$((p + n + 4))" -le "$size" ] || return 1
        key=${body:$((p * 2)):$((n * 2))}
        p=$((p + n))
        v=$((16#${body:$((p * 2)):8}))
        p=$((p + 4))
        [ "$((p + v))" -le "$size" ] || return 1
        val=${body:$((p * 2)):$((v * 2))}
        [ "$key" != 536f636b65742d54797065 ] || {
            [ "$val" = 505542 ] || [ "$val" = 58505542 ]
            return
        }
        p=$((p + v))
    done
    return 1
}

zmq_endpoint_is_publisher() { # <host> <port>
    local reply greeting ready rc=0
    reply=$(timeout 5 bash -c '
        exec 3<>/dev/tcp/"$0"/"$1" 2>/dev/null || exit 1
        { printf "\xff\x00\x00\x00\x00\x00\x00\x00\x00\x7f\x03\x01NULL"; head -c 48 /dev/zero; } >&3
        g=$(head -c 64 <&3 | od -An -v -tx1 | tr -d " \n")
        t=${g:64}
        [ ${#g} -eq 128 ] && [ "${g:0:2}" = ff ] && [ "${g:18:2}" = 7f ] && [ $((16#${g:20:2})) -ge 3 ] && [ "${g:24:40}" = 4e554c4c00000000000000000000000000000000 ] && [ "$t" = "${t//[!0]/}" ] || { printf "%s\n" "$g"; exit 2; }
        printf "\x04\x19\x05READY\x0bSocket-Type\x00\x00\x00\x03SUB" >&3
        h=$(head -c 2 <&3 | od -An -v -tx1 | tr -d " \n")
        [ ${#h} -eq 4 ] && [ $((16#${h:0:2} & 2)) -eq 0 ] || exit 2
        b=$(head -c "$((16#${h:2:2}))" <&3 | od -An -v -tx1 | tr -d " \n")
        printf "%s\n%s%s" "$g" "$h" "$b"' "$1" "$2" 2>/dev/null) || rc=$?
    greeting=${reply%%$'\n'*}
    ready=${reply#*$'\n'}
    case "$rc" in 0 | 2) NODE_PROBE_REASON=protocol ;; 124) NODE_PROBE_REASON=timeout ;; *) NODE_PROBE_REASON=refused ;; esac
    [ "$rc" -eq 0 ] && zmq_greeting_ok "$greeting" && zmq_ready_is_publisher "$ready" || return 1
    NODE_PROBE_REASON=ok
}

monero_rpc_speaks() { # <config-file> <host> <port>
    local cfg="$1" host="$2" port="$3" user pass url_host auth="" body code rc=0
    local -a auth_args=()
    user=$(jq -r '.monero.node_username // ""' "$cfg")
    pass=$(jq -r '.monero.node_password // ""' "$cfg")
    url_host="$host"
    case "$url_host" in \[*\]) ;; *:*) url_host="[$url_host]" ;; esac
    [ -z "$user" ] || { auth=$(printf '%s:%s' "$user" "$pass" | jq -Rs .) && auth_args=(--digest); }
    body=$(printf '%s' "${auth:+user = $auth}" | timeout 6 curl -sS --noproxy '*' --max-time 5 \
        --max-filesize "${CURL_CAP_SMALL:-1048576}" "${auth_args[@]}" --config - \
        -w '\n%{http_code}' "http://$url_host:$port/get_info" 2>/dev/null) || rc=$?
    if [ "$rc" -ne 0 ]; then
        case "$rc" in 7) NODE_PROBE_REASON=refused ;; 28 | 124) NODE_PROBE_REASON=timeout ;; 63) NODE_PROBE_REASON=unusable ;; 127) NODE_PROBE_REASON="missing-tool" ;; *) NODE_PROBE_REASON=unknown ;; esac
        return 1
    fi
    code=${body##*$'\n'}
    body=${body%$'\n'*}
    case "$code" in 200) ;; 401 | 403) NODE_PROBE_REASON=auth && return 1 ;; *) NODE_PROBE_REASON=protocol && return 1 ;; esac
    printf '%s' "$body" | jq -e '(.status == "OK") and
        (.nettype | IN("mainnet", "testnet", "stagenet")) and
        ([.height, .target_height] | all(type == "number" and
            (tostring | test("^(0|[1-9][0-9]*)$"))))' >/dev/null 2>&1 || {
        NODE_PROBE_REASON=protocol
        return 1
    }
    NODE_PROBE_REASON=ok
}

remote_node_addresses_allowed() { # <config-file>
    local cfg="$1" host port
    if [ "$(jq -r '.monero.mode // "local"' "$cfg")" = remote ]; then
        host=$(jq -r '.monero.remote.host // ""' "$cfg")
        port=$(jq -r '.monero.remote.rpc_port // 18081' "$cfg")
        remote_node_address "$cfg" "$host" >/dev/null || {
            case "$?" in 2) NODE_PROBE_REASON=dns ;; *) NODE_PROBE_REASON=address ;; esac
            [ "$NODE_PROBE_REASON" != dns ] || printf 'the remote Monero node name %s does not resolve from this machine — check it for a typo, or give a numeric address' "$host"
            [ "$NODE_PROBE_REASON" = dns ] || printf 'cannot use the remote Monero node at %s:%s — use an address allowed by network.tor_egress_firewall' "$host" "$port"
            return 1
        }
    fi
    if [ "$(jq -r '.tari.mode // "local"' "$cfg")" = remote ]; then
        host=$(jq -r '.tari.remote.host // ""' "$cfg")
        port=$(jq -r '.tari.remote.grpc_port // 18142' "$cfg")
        remote_node_address "$cfg" "$host" >/dev/null || {
            case "$?" in 2) NODE_PROBE_REASON=dns ;; *) NODE_PROBE_REASON=address ;; esac
            [ "$NODE_PROBE_REASON" != dns ] || printf 'the remote Tari node name %s does not resolve from this machine — check it for a typo, or give a numeric address' "$host"
            [ "$NODE_PROBE_REASON" = dns ] || printf 'cannot use the remote Tari node at %s:%s — use an address allowed by network.tor_egress_firewall and check tari.grpc_lan_access' "$host" "$port"
            return 1
        }
    fi
}

preflight_remote_nodes() { # <config-file>
    local cfg="$1" host address port zmq
    remote_node_addresses_allowed "$cfg" || return
    if [ "$(jq -r '.monero.mode // "local"' "$cfg")" = remote ]; then
        host=$(jq -r '.monero.remote.host // ""' "$cfg")
        port=$(jq -r '.monero.remote.rpc_port // 18081' "$cfg")
        zmq=$(jq -r '.monero.remote.zmq_port // 18083' "$cfg")
        address=$(remote_node_address "$cfg" "$host") || {
            case "$?" in 2) NODE_PROBE_REASON=dns ;; *) NODE_PROBE_REASON=address ;; esac
            [ "$NODE_PROBE_REASON" != dns ] || printf 'the remote Monero node name %s does not resolve from this machine — check it for a typo, or give a numeric address' "$host"
            [ "$NODE_PROBE_REASON" = dns ] || printf 'cannot use the remote Monero node at %s:%s — use an address allowed by network.tor_egress_firewall' "$host" "$port"
            return 1
        }
        if ! monero_rpc_speaks "$cfg" "$address" "$port"; then
            case "$NODE_PROBE_REASON" in
            auth) printf 'the remote Monero node at %s:%s rejected the configured RPC login' "$host" "$port" ;;
            protocol) printf 'the endpoint at %s:%s answered, but did not return a usable monerod get_info response' "$host" "$port" ;;
            unusable) printf 'the remote Monero node at %s:%s returned more than 1 MiB to get_info — refusing the response' "$host" "$port" ;;
            missing-tool) printf 'cannot check the remote Monero node because curl is missing from this machine' ;;
            *) printf 'cannot reach the remote Monero node at %s:%s — check the host, port, and monero.rpc_lan_access' "$host" "$port" ;;
            esac
            return 1
        fi
        if ! zmq_endpoint_is_publisher "$address" "$zmq"; then
            [ "$NODE_PROBE_REASON" != protocol ] || printf 'the endpoint at %s:%s speaks ZMQ but did not complete a publisher handshake' "$host" "$zmq"
            [ "$NODE_PROBE_REASON" = protocol ] || printf 'cannot reach the remote Monero node at %s:%s — check the host, port, and zmq_lan_access' "$host" "$zmq"
            return 1
        fi
    fi
    if [ "$(jq -r '.tari.mode // "local"' "$cfg")" = remote ]; then
        host=$(jq -r '.tari.remote.host // ""' "$cfg")
        port=$(jq -r '.tari.remote.grpc_port // 18142' "$cfg")
        address=$(remote_node_address "$cfg" "$host") || {
            case "$?" in 2) NODE_PROBE_REASON=dns ;; *) NODE_PROBE_REASON=address ;; esac
            [ "$NODE_PROBE_REASON" != dns ] || printf 'the remote Tari node name %s does not resolve from this machine — check it for a typo, or give a numeric address' "$host"
            [ "$NODE_PROBE_REASON" = dns ] || printf 'cannot use the remote Tari node at %s:%s — use an address allowed by network.tor_egress_firewall and check tari.grpc_lan_access' "$host" "$port"
            return 1
        }
        if ! timeout 5 bash -c "</dev/tcp/$address/$port" 2>/dev/null; then
            printf 'cannot reach the remote Tari node at %s:%s — check the host, port, and tari.grpc_lan_access' "$host" "$port"
            return 1
        fi
    fi
}
