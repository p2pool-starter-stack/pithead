_render_env_dashboard_go() {
    local binary="${_pithead_go_hybrid_binary:-}" native_rc native_extra platform
    if [ "${PITHEAD_IMPL:-}" = go ]; then binary="${PITHEAD_GO_BINARY:-${PITHEAD_GO_CONFIG_DOCUMENT_BINARY:-}}"; elif [ "${_PITHEAD_GO_HYBRID:-}" = 1 ]; then binary="${PITHEAD_GO_CONFIG_DOCUMENT_BINARY:-}"; fi
    [ -n "$binary" ] && [ -x "$binary" ] && command -v cat >/dev/null 2>&1 || return 125
    platform=$(config_platform) || return 125
    {
        IFS= read -r -d '' xvb_enabled &&
            IFS= read -r -d '' xvb_tor &&
            IFS= read -r -d '' xvb_url &&
            IFS= read -r -d '' xvb_donor &&
            IFS= read -r -d '' xvb_donation_level &&
            IFS= read -r -d '' tari_required &&
            IFS= read -r -d '' fail_closed &&
            IFS= read -r -d '' hc_ping_url &&
            IFS= read -r -d '' xvb_standby_source &&
            IFS= read -r -d '' check_for_updates &&
            IFS= read -r -d '' worker_api_port &&
            IFS= read -r -d '' worker_api_auth &&
            IFS= read -r -d '' worker_api_token &&
            IFS= read -r -d '' worker_api_tokens_json &&
            IFS= read -r -d '' tg_enabled &&
            IFS= read -r -d '' tg_token &&
            IFS= read -r -d '' tg_chat &&
            IFS= read -r -d '' tg_commands &&
            IFS= read -r -d '' tg_ev_node_down &&
            IFS= read -r -d '' tg_ev_node_recovered &&
            IFS= read -r -d '' tg_ev_worker_offline &&
            IFS= read -r -d '' tg_ev_worker_recovered &&
            IFS= read -r -d '' tg_ev_worker_joined &&
            IFS= read -r -d '' tg_ev_worker_left &&
            IFS= read -r -d '' tg_ev_sync_finished &&
            IFS= read -r -d '' tg_ev_disk_space &&
            IFS= read -r -d '' tg_ev_db_unhealthy &&
            IFS= read -r -d '' tg_ev_db_reset &&
            IFS= read -r -d '' tg_ev_xvb_no_share &&
            IFS= read -r -d '' tg_ev_clearnet_exposed &&
            IFS= read -r -d '' tg_ev_xvb_registration &&
            IFS= read -r -d '' tg_ev_new_release &&
            IFS= read -r -d '' tg_ev_stack_online &&
            IFS= read -r -d '' tg_ev_daily_summary &&
            IFS= read -r -d '' tg_ev_hashrate_low &&
            IFS= read -r -d '' tg_ev_hashrate_loss &&
            IFS= read -r -d '' tg_ev_hugepages &&
            IFS= read -r -d '' tg_ev_low_ram &&
            IFS= read -r -d '' tg_ev_wallet_changed &&
            IFS= read -r -d '' tg_ev_high_reject_rate &&
            IFS= read -r -d '' tg_ev_block_found &&
            IFS= read -r -d '' tg_ev_payout_found &&
            IFS= read -r -d '' tg_ev_payout_confirmed &&
            IFS= read -r -d '' tg_ev_container_unhealthy &&
            IFS= read -r -d '' tg_ev_raffle_win &&
            IFS= read -r -d '' hr_drop_threshold &&
            IFS= read -r -d '' hr_drop_minutes &&
            IFS= read -r -d '' tg_summary_time &&
            IFS= read -r -d '' notify_webhooks &&
            IFS= read -r -d '' ntfy_url &&
            IFS= read -r -d '' ntfy_token &&
            IFS= read -r -d '' notify_tor &&
            IFS= read -r -d '' native_rc && [ "$native_rc" = 0 ] &&
            { ! IFS= read -r -d '' native_extra && [ -z "$native_extra" ]; }
    } < <(
        local producer_rc=0 helper_rc=0
        {
            printf '%s\0' "$platform" "$TARI_MODE" "$MONERO_WALLET" || producer_rc=$?
            config_defaults_json || producer_rc=$?
            printf '\0' || producer_rc=$?
            cat "$CONFIG_FILE" || producer_rc=$?
            printf '\0%d\0' "$producer_rc"
        } | PITHEAD_GO_HELPER=config-env-dashboard "$binary" 2>/dev/null || helper_rc=$?
        printf '%d\0' "$helper_rc"
    ) || return 125
}
