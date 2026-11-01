_parse_network_config_go() {
    local binary="${_pithead_go_hybrid_binary:-}" assigned reason native_rc extra index
    local -a values=() names=(
        NETWORK_SUBNET NETWORK_PREFIX TOR_EGRESS_FIREWALL TOR_AUTO_HEAL
        TARI_EXPLORER_URL P2POOL_CLEARNET MONERO_REMOTE_HOST MONERO_REMOTE_RPC_PORT
        MONERO_REMOTE_ZMQ_PORT TARI_REMOTE_HOST TARI_REMOTE_GRPC_PORT POOL_TYPE
    )
    if [ "${PITHEAD_IMPL:-}" = go ]; then binary="${PITHEAD_GO_BINARY:-${PITHEAD_GO_CONFIG_DOCUMENT_BINARY:-}}"; elif [ "${_PITHEAD_GO_HYBRID:-}" = 1 ]; then binary="${PITHEAD_GO_CONFIG_DOCUMENT_BINARY:-}"; fi
    [ -n "$binary" ] && [ -x "$binary" ] || return 125
    {
        IFS= read -r -d '' assigned &&
            {
                for ((index = 0; index < 12; index++)); do
                    IFS= read -r -d '' "values[index]" || return 125
                done
            } &&
            IFS= read -r -d '' reason &&
            IFS= read -r -d '' native_rc && [ "$native_rc" = 0 ] &&
            { ! IFS= read -r -d '' extra && [ -z "$extra" ]; }
    } < <(
        local helper_rc=0
        PITHEAD_GO_HELPER=config-network-settings "$binary" "$CONFIG_FILE" "$MONERO_MODE" "$TARI_MODE" 2>/dev/null || helper_rc=$?
        printf '%d\0' "$helper_rc"
    ) || return 125
    case "$assigned" in
    1 | 2 | 11) [ -n "$reason" ] || return 125 ;;
    12) ;;
    *) return 125 ;;
    esac
    for ((index = 0; index < assigned; index++)); do
        printf -v "${names[index]}" '%s' "${values[index]}"
    done
    [ -z "$reason" ] || error "$reason"
    return 0
}
