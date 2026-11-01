_render_env_network_go() {
    local binary="${_pithead_go_hybrid_binary:-}" native_rc native_extra
    if [ "${PITHEAD_IMPL:-}" = go ]; then binary="${PITHEAD_GO_BINARY:-${PITHEAD_GO_CONFIG_DOCUMENT_BINARY:-}}"; elif [ "${_PITHEAD_GO_HYBRID:-}" = 1 ]; then binary="${PITHEAD_GO_CONFIG_DOCUMENT_BINARY:-}"; fi
    [ -n "$binary" ] && [ -x "$binary" ] && command -v cat >/dev/null 2>&1 || return 125
    {
        IFS= read -r -d '' mono_host &&
            IFS= read -r -d '' rpc_port &&
            IFS= read -r -d '' zmq_port &&
            IFS= read -r -d '' mono_rpc_url &&
            IFS= read -r -d '' profiles &&
            IFS= read -r -d '' tari_grpc_addr &&
            IFS= read -r -d '' tor_profiles &&
            IFS= read -r -d '' tari_grpc_bind &&
            IFS= read -r -d '' prune &&
            IFS= read -r -d '' monero_clearnet &&
            IFS= read -r -d '' tari_clearnet &&
            IFS= read -r -d '' prep_threads &&
            IFS= read -r -d '' out_peers &&
            IFS= read -r -d '' rpc_bind &&
            IFS= read -r -d '' zmq_bind &&
            IFS= read -r -d '' pool_type &&
            IFS= read -r -d '' p2pool_flags &&
            IFS= read -r -d '' p2pool_port &&
            IFS= read -r -d '' p2pool_socks &&
            IFS= read -r -d '' native_rc && [ "$native_rc" = 0 ] &&
            { ! IFS= read -r -d '' native_extra && [ -z "$native_extra" ]; }
    } < <(
        local producer_rc=0 helper_rc=0
        {
            printf '%s\0' "$MONERO_MODE" "$TARI_MODE" "$NETWORK_PREFIX" \
                "${MONERO_REMOTE_HOST:-}" "${MONERO_REMOTE_RPC_PORT:-}" "${MONERO_REMOTE_ZMQ_PORT:-}" \
                "${TARI_REMOTE_HOST:-}" "${TARI_REMOTE_GRPC_PORT:-}" \
                "${PAYOUT_CONFIRM_ENABLED:-false}" "${TARI_PAYOUT_CONFIRM_ENABLED:-false}" || producer_rc=$?
            cat "$CONFIG_FILE" || producer_rc=$?
            printf '\0%d\0' "$producer_rc"
        } | PITHEAD_GO_HELPER=config-env-network "$binary" 2>/dev/null || helper_rc=$?
        printf '%d\0' "$helper_rc"
    ) || return 125
}
