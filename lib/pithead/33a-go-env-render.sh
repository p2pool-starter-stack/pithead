_render_env_go() {
    local binary="${PITHEAD_GO_CONFIG_DOCUMENT_BINARY:-}" producer_rc=0 parent="${1%/*}"
    if [ "${PITHEAD_IMPL:-}" = go ]; then binary="${PITHEAD_GO_BINARY:-$binary}"; fi
    [ -n "$binary" ] && [ -x "$binary" ] && command -v cat >/dev/null 2>&1 || return 125
    if [ -e "$1" ] || [ -L "$1" ]; then
        [ -f "$1" ] && [ -w "$1" ] || return 125
    else
        [ "$parent" != "$1" ] || parent=.
        [ -n "$parent" ] || parent=/
        [ -d "$parent" ] && [ -w "$parent" ] || return 125
    fi
    case "${LC_ALL:-${LC_CTYPE:-${LANG:-C}}}" in
    C | POSIX | *.[uU][tT][fF]-8 | *.[uU][tT][fF]8 | [uU][tT][fF]-8 | [uU][tT][fF]8) ;;
    *) return 125 ;;
    esac
    {
        printf '%s\0' \
            MONERO_DATA_DIR "$MONERO_DIR" \
            TARI_DATA_DIR "$TARI_DIR" \
            P2POOL_DATA_DIR "$P2POOL_DIR" \
            DASHBOARD_DATA_DIR "$DASHBOARD_DIR" \
            TOR_DATA_DIR "$TOR_DATA_DIR" \
            MONERO_NODE_USERNAME "$MONERO_USER" \
            MONERO_NODE_PASSWORD "$MONERO_PASS" \
            MONERO_WALLET_ADDRESS "$MONERO_WALLET" \
            MONERO_VIEW_KEY "$MONERO_VIEW_KEY" \
            PAYOUT_SCAN_HEIGHT "$PAYOUT_SCAN_HEIGHT" \
            PAYOUT_CONFIRM_ENABLED "$PAYOUT_CONFIRM_ENABLED" \
            WALLET_RPC_USERNAME "wallet" \
            WALLET_RPC_PASSWORD "$WALLET_RPC_PASSWORD" \
            MONERO_WALLET_RPC_URL "http://127.0.0.1:18082/json_rpc" \
            TARI_WALLET_ADDRESS "${TARI_WALLET:-your_tari_wallet_address}" \
            TARI_VIEW_KEY "$TARI_VIEW_KEY" \
            TARI_SPEND_PUBLIC_KEY "$TARI_SPEND_PUBLIC_KEY" \
            TARI_WALLET_PASSWORD "$TARI_WALLET_PASSWORD" \
            TARI_WALLET_BIRTHDAY "$TARI_WALLET_BIRTHDAY" \
            TARI_PAYOUT_CONFIRM_ENABLED "$TARI_PAYOUT_CONFIRM_ENABLED" \
            TARI_WALLET_GRPC_ADDRESS "127.0.0.1:18143" \
            TARI_WALLET_SECRET_FILE "$tari_secret_file" \
            MONERO_ONION_ADDRESS "$MONERO_ONION" \
            TARI_ONION_ADDRESS "$TARI_ONION" \
            P2POOL_ONION_ADDRESS "$P2POOL_ONION" \
            DASHBOARD_ONION_ADDRESS "$DASHBOARD_ONION" \
            DASHBOARD_ONION_CLIENT_PUBKEY "$DASHBOARD_ONION_CLIENT_PUBKEY" \
            DASHBOARD_ONION_CLIENT_PRIVKEY "$DASHBOARD_ONION_CLIENT_PRIVKEY" \
            P2POOL_FLAGS "$p2pool_flags" \
            P2POOL_PORT "$p2pool_port" \
            STRATUM_BIND "$STRATUM_BIND" \
            STRATUM_PORT "$STRATUM_PORT" \
            PROXY_STRATUM_PASSWORD "$STRATUM_PASSWORD" \
            PROXY_STRATUM_TLS "$STRATUM_TLS" \
            STRATUM_TLS_FINGERPRINT "$env_fingerprint" \
            PROXY_TLS_DIR "$PROXY_TLS_DIR" \
            XVB_POOL_URL "$xvb_url" \
            XVB_DONOR_ID "$xvb_donor" \
            XVB_ENABLED "$xvb_enabled" \
            XVB_TOR_ENABLED "$xvb_tor" \
            XVB_DONATION_LEVEL "$xvb_donation_level" \
            TARI_REQUIRED "$tari_required" \
            DASHBOARD_FAIL_CLOSED "$fail_closed" \
            DASHBOARD_CHECK_UPDATES "$check_for_updates" \
            TARI_MEM_LIMIT "$tari_mem_limit" \
            HEALTHCHECKS_PING_URL "$hc_ping_url" \
            XVB_STANDBY_SOURCE "$xvb_standby_source" \
            TELEGRAM_ENABLED "$tg_enabled" \
            TELEGRAM_BOT_TOKEN "$tg_token" \
            TELEGRAM_CHAT_ID "$tg_chat" \
            TELEGRAM_COMMANDS_ENABLED "$tg_commands" \
            TELEGRAM_EVENT_NODE_DOWN "$tg_ev_node_down" \
            TELEGRAM_EVENT_NODE_RECOVERED "$tg_ev_node_recovered" \
            TELEGRAM_EVENT_WORKER_OFFLINE "$tg_ev_worker_offline" \
            TELEGRAM_EVENT_WORKER_RECOVERED "$tg_ev_worker_recovered" \
            TELEGRAM_EVENT_WORKER_JOINED "$tg_ev_worker_joined" \
            TELEGRAM_EVENT_WORKER_LEFT "$tg_ev_worker_left" \
            TELEGRAM_EVENT_SYNC_FINISHED "$tg_ev_sync_finished" \
            TELEGRAM_EVENT_DISK_SPACE "$tg_ev_disk_space" \
            TELEGRAM_EVENT_DB_UNHEALTHY "$tg_ev_db_unhealthy" \
            TELEGRAM_EVENT_DB_RESET "$tg_ev_db_reset" \
            TELEGRAM_EVENT_XVB_NO_SHARE "$tg_ev_xvb_no_share" \
            TELEGRAM_EVENT_CLEARNET_EXPOSED "$tg_ev_clearnet_exposed" \
            TELEGRAM_EVENT_XVB_REGISTRATION "$tg_ev_xvb_registration" \
            TELEGRAM_EVENT_NEW_RELEASE "$tg_ev_new_release" \
            TELEGRAM_EVENT_STACK_ONLINE "$tg_ev_stack_online" \
            TELEGRAM_EVENT_DAILY_SUMMARY "$tg_ev_daily_summary" \
            TELEGRAM_EVENT_HASHRATE_LOW "$tg_ev_hashrate_low" \
            TELEGRAM_EVENT_HASHRATE_LOSS "$tg_ev_hashrate_loss" \
            TELEGRAM_EVENT_HUGEPAGES "$tg_ev_hugepages" \
            TELEGRAM_EVENT_LOW_RAM "$tg_ev_low_ram" \
            TELEGRAM_EVENT_WALLET_CHANGED "$tg_ev_wallet_changed" \
            TELEGRAM_EVENT_HIGH_REJECT_RATE "$tg_ev_high_reject_rate" \
            TELEGRAM_EVENT_BLOCK_FOUND "$tg_ev_block_found" \
            TELEGRAM_EVENT_PAYOUT_FOUND "$tg_ev_payout_found" \
            TELEGRAM_EVENT_PAYOUT_CONFIRMED "$tg_ev_payout_confirmed" \
            TELEGRAM_EVENT_CONTAINER_UNHEALTHY "$tg_ev_container_unhealthy" \
            TELEGRAM_EVENT_RAFFLE_WIN "$tg_ev_raffle_win" \
            HASHRATE_DROP_THRESHOLD_PCT "$hr_drop_threshold" \
            HASHRATE_DROP_MINUTES "$hr_drop_minutes" \
            TELEGRAM_DAILY_SUMMARY_TIME "$tg_summary_time" \
            NOTIFY_WEBHOOK_URLS "$notify_webhooks" \
            NTFY_URL "$ntfy_url" \
            NTFY_TOKEN "$ntfy_token" \
            NOTIFY_TOR "$notify_tor" \
            MONERO_MEM_LIMIT "$monero_mem_limit" \
            P2POOL_URL "${NETWORK_PREFIX}.28:3333" \
            NETWORK_SUBNET "$NETWORK_SUBNET" \
            NETWORK_PREFIX "$NETWORK_PREFIX" \
            TOR_EGRESS_FIREWALL "$TOR_EGRESS_FIREWALL" \
            TOR_AUTO_HEAL "$TOR_AUTO_HEAL" \
            TARI_EXPLORER_URL "$TARI_EXPLORER_URL" \
            P2POOL_CLEARNET "$P2POOL_CLEARNET" \
            PROXY_API_PORT "3344" \
            PROXY_AUTH_TOKEN "$PROXY_AUTH_TOKEN" \
            XMRIG_API_PORT "$worker_api_port" \
            XMRIG_API_AUTH "$worker_api_auth" \
            XMRIG_API_TOKEN "$worker_api_token" \
            WORKER_API_TOKENS "$worker_api_tokens_json" \
            PROXY_DONATE_LEVEL "$DONATE_LEVEL" \
            MONERO_PRUNE "$prune" \
            MONERO_CLEARNET_SYNC "$monero_clearnet" \
            TARI_CLEARNET_SYNC "$tari_clearnet" \
            CLEARNET_STATE_DIR "$CLEARNET_STATE_DIR" \
            MONERO_PREP_THREADS "$prep_threads" \
            MONERO_OUT_PEERS "$out_peers" \
            MONERO_RPC_BIND "$rpc_bind" \
            MONERO_ZMQ_BIND "$zmq_bind" \
            MONERO_NODE_HOST "$mono_host" \
            MONERO_RPC_URL "$mono_rpc_url" \
            MONERO_RPC_PORT "$rpc_port" \
            MONERO_ZMQ_PORT "$zmq_port" \
            TARI_MODE "$TARI_MODE" \
            TARI_GRPC_ADDRESS "$tari_grpc_addr" \
            TARI_GRPC_BIND "$tari_grpc_bind" \
            COMPOSE_PROJECT_NAME "$project" \
            COMPOSE_PROFILES "$profiles" \
            TOR_COMPOSE_PROFILES "$tor_profiles" \
            DASHBOARD_SECURE "$DASHBOARD_SECURE" \
            DASHBOARD_EXPOSE_PUBLIC_IP "$DASHBOARD_EXPOSE_PUBLIC_IP" \
            DASHBOARD_ONION_ENABLED "$DASHBOARD_ONION_ENABLED" \
            DASHBOARD_ONION_CLIENT_AUTH "$DASHBOARD_ONION_CLIENT_AUTH" \
            DASHBOARD_TZ "$DASHBOARD_TZ" \
            DASHBOARD_AUTH_USER "$DASHBOARD_AUTH_USER" \
            DASHBOARD_AUTH_HASH_B64 "$DASHBOARD_AUTH_HASH_B64" \
            DASHBOARD_AUTH_PW_FP "$DASHBOARD_AUTH_PW_FP" \
            DASHBOARD_CONTROL_ENABLED "$DASHBOARD_CONTROL_ENABLED" \
            CONTROL_DIR "$CONTROL_DIR" \
            CADDY_LOG_DIR "$CADDY_LOG_DIR" \
            HOST_IP "$HOST_IP" \
            PITHEAD_TLS_DIR "$env_tls_dir" \
            HOST_PORT "$HOST_PORT" \
            DEPLOYMENT_COMPLETED "${DEPLOYMENT_COMPLETED:-false}" || producer_rc=$?
        printf '\0%d\0' "$producer_rc"
    } | PITHEAD_GO_HELPER=config-env "$binary"
}
