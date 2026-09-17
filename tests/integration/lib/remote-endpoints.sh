# shellcheck shell=bash
# Remote-node endpoint validation, forwarding and public-output masking.

valid_remote_host() { [[ -n "$1" && ${#1} -le 253 && "$1" != *[!A-Za-z0-9._:-]* ]]; }
valid_tcp_port() { [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }

add_remote_node_arg() { # <flag> <value>; appends to e2e's endpoint arrays
    local flag="$1" value="$2"
    case "$flag" in
    --remote-monero-host | --remote-tari-host)
        valid_remote_host "$value" && [[ "$value" != *:* ]] || return 1
        REMOTE_NODE_HOSTS+=("$value")
        ;;
    --remote-monero-rpc-port | --remote-monero-zmq-port)
        valid_tcp_port "$value" || return 1
        ;;
    *) return 1 ;;
    esac
    REMOTE_NODE_ARGS+=("$flag" "$value")
}

redact_remote_output() {
    local line host
    while IFS= read -r line; do
        line="$(printf '%s\n' "$line" | redact)"
        for host in "${REMOTE_NODE_HOSTS[@]:-}"; do
            [ -z "$host" ] || line="${line//"$host"/<redacted-endpoint>}"
        done
        printf '%s\n' "$line"
    done
}
