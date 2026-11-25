render_env() {
    local target="${1:-$ENV_FILE}" project profile
    profile=$(profile_name)
    project=$(compose_project_name) || return 1
    log "Rendering environment configuration ($target)..."
    local -A setting
    local setting_lines setting_key setting_value
    setting_lines=$(render_env_settings)
    while IFS=$'\t' read -r setting_key setting_value; do setting[$setting_key]=$setting_value; done <<<"$setting_lines"

    local mono_host rpc_port zmq_port mono_rpc_url profiles
    if [ "$MONERO_MODE" == "local" ]; then
        mono_host="${NETWORK_PREFIX}.26" rpc_port="18081" zmq_port="18083" profiles="local_node"
        mono_rpc_url="http://127.0.0.1:18081" # host loopback, not the bridge IP above
    else
        # Reuse the parse-time validated globals — the validated value IS the rendered value.
        mono_host="$MONERO_REMOTE_HOST" rpc_port="$MONERO_REMOTE_RPC_PORT" zmq_port="$MONERO_REMOTE_ZMQ_PORT"
        profiles="" # Empty profile disables local monerod
        # Bracket a literal IPv6 host for URL use (RFC 3986).
        case "$mono_host" in *:*) mono_rpc_url="http://[$mono_host]:$rpc_port" ;; *) mono_rpc_url="http://$mono_host:$rpc_port" ;; esac
    fi

    # Tari mode → gRPC address / compose profile (#103/#1855), mirroring Monero above. local -> the
    # bundled node at its bridge IP plus the local_tari profile. remote -> a third-party node's
    # host:port. off -> neither profile nor merge-mining, so the address stays the stock local
    # default as an INERT placeholder: the profiled-off tari service still interpolates it, and
    # p2pool's entrypoint is to drop the --merge-mine triple from argv on TARI_MODE=off (#1903).
    local tari_grpc_addr="${NETWORK_PREFIX}.27:18142"
    if [ "$TARI_MODE" == "local" ]; then
        profiles="${profiles:+$profiles,}local_tari"
    elif [ "$TARI_MODE" == "remote" ]; then
        # Reuse the parse-time validated globals (see Monero above) — single source of truth.
        tari_grpc_addr="${TARI_REMOTE_HOST}:${TARI_REMOTE_GRPC_PORT}"
    fi
    local tor_profiles="$profiles"

    local tari_grpc_bind tari_grpc_lan
    tari_grpc_lan=${setting[tari_grpc_lan]}
    if [ "$tari_grpc_lan" == "true" ]; then tari_grpc_bind="0.0.0.0"; else tari_grpc_bind="127.0.0.1"; fi

    if [ "${PAYOUT_CONFIRM_ENABLED:-false}" == "true" ]; then
        profiles="${profiles:+$profiles,}payout_confirm"
    fi

    # Tari on-chain payout confirmation (#462) uses its own profile when a view key is set on a
    # local Tari node, independently of Monero's payout_confirm.
    # TARI_PAYOUT_CONFIRM_ENABLED is set by parse_and_validate_config (which also refuses a view key
    # on a remote Tari node and validates the key/spend key/birthday).
    if [ "${TARI_PAYOUT_CONFIRM_ENABLED:-false}" == "true" ]; then
        profiles="${profiles:+$profiles,}tari_payout_confirm"
    fi

    # Pruning is on unless config explicitly sets monero.prune:false (config_bool honours that
    # explicit false rather than coercing it back to the default — see #294).
    local prune
    prune=$(monero_prune_flag)

    local monero_clearnet tari_clearnet
    monero_clearnet=$(normalize_bool "${setting[monero_clearnet]}")
    tari_clearnet=$(normalize_bool "${setting[tari_clearnet]}")

    [ "$MONERO_MODE" = local ] || monero_clearnet=false
    [ "$TARI_MODE" = local ] || tari_clearnet=false

    local prep_threads cores
    prep_threads=${setting[prep_threads]}
    if ! [[ "$prep_threads" =~ ^[0-9]+$ ]]; then
        cores=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)
        prep_threads=$((cores - 2))
        [ "$prep_threads" -lt 4 ] && prep_threads=4
        [ "$prep_threads" -gt 8 ] && prep_threads=8
    fi

    local out_peers
    out_peers=${setting[out_peers]}
    if ! [[ "$out_peers" =~ ^[0-9]+$ ]] || [ "$out_peers" -lt 8 ] || [ "$out_peers" -gt 1024 ]; then
        error "monero.out_peers must be an integer between 8 and 1024 (got \"$out_peers\")."
    fi

    local rpc_bind rpc_lan
    rpc_lan=${setting[rpc_lan]}
    if [ "$rpc_lan" == "true" ]; then rpc_bind="0.0.0.0"; else rpc_bind="127.0.0.1"; fi

    local zmq_bind zmq_lan
    zmq_lan=${setting[zmq_lan]}
    if [ "$zmq_lan" == "true" ]; then zmq_bind="0.0.0.0"; else zmq_bind="127.0.0.1"; fi

    local pool_type p2pool_flags p2pool_port
    pool_type=${setting[pool_type]}
    p2pool_flags=""
    p2pool_port="37889"
    if [ "$pool_type" == "mini" ]; then
        p2pool_flags="--mini"
        p2pool_port="37888"
    elif [ "$pool_type" == "nano" ]; then
        p2pool_flags="--nano"
        p2pool_port="37890"
    fi

    if p2pool_needs_light_mode; then
        p2pool_flags="${p2pool_flags:+$p2pool_flags }--light-mode"
    fi

    local p2pool_socks
    p2pool_socks=$(p2pool_outbound_flags "${setting[p2pool_clearnet]}" "$NETWORK_PREFIX")
    [ -n "$p2pool_socks" ] && p2pool_flags="${p2pool_flags:+$p2pool_flags }$p2pool_socks"

    p2pool_flags="${p2pool_flags:+$p2pool_flags }--no-upnp"
    if [ "$profile" = privacy ] && [ "$P2POOL_CLEARNET" != true ]; then
        p2pool_flags+=" --no-clearnet-p2p"
    fi

    local xvb_enabled xvb_url xvb_donor xvb_donation_level xvb_tor
    xvb_enabled=${setting[xvb_enabled]}
    xvb_tor=$(normalize_bool "${setting[xvb_tor]}")
    xvb_url=${setting[xvb_url]}
    [ -z "$xvb_url" ] && xvb_url="na.xmrvsbeast.com:4247"
    xvb_donor=${setting[xvb_donor]}
    case "$xvb_donor" in
    "" | auto | DYNAMIC_ID) xvb_donor="${MONERO_WALLET:0:8}" ;;
    esac
    xvb_donation_level=${setting[xvb_donation_level]}
    [ -z "$xvb_donation_level" ] && xvb_donation_level="auto"

    local donation_enabled donation_percent donation_tor
    donation_enabled=${setting[donation_enabled]}
    donation_percent=${setting[donation_percent]}
    donation_tor=${setting[donation_tor]}

    local tari_required
    tari_required=${setting[tari_required]}
    [ "$TARI_MODE" != "off" ] || tari_required=false

    local fail_closed
    fail_closed=$(normalize_bool "${setting[fail_closed]}")

    local hc_ping_url
    hc_ping_url=${setting[hc_ping_url]}

    local xvb_standby_source
    xvb_standby_source=${setting[xvb_standby_source]}

    local check_for_updates
    check_for_updates=${setting[check_for_updates]}

    local worker_api_port worker_api_auth worker_api_token worker_api_tokens_json
    worker_api_port=${setting[worker_api_port]}
    worker_api_auth=${setting[worker_api_auth]}
    worker_api_token=${setting[worker_api_token]}
    if [ "$worker_api_token" = auto ]; then
        worker_api_token=$(env_get XMRIG_API_TOKEN)
        [ -n "$worker_api_token" ] || worker_api_token=$(openssl rand -hex 24)
    fi
    worker_api_tokens_json=$(jq -c '(.workers.api_port // 8080) as $port | reduce ((.workers.list // [])[] | select((.name // "") != "" and (.host // "") != "" and (.api_token // "") != "")) as $worker ({}; .[$worker.name] //= {host: $worker.host, port: ($worker.port // $port), token: $worker.api_token})' "$CONFIG_FILE")

    local tg_level tg_token tg_chat tg_commands tg_summary_time
    tg_level=${setting[tg_level]}
    tg_token=${setting[tg_token]}
    tg_chat=${setting[tg_chat]}
    tg_commands=${setting[tg_commands]}
    local hr_drop_threshold hr_drop_minutes
    hr_drop_threshold=${setting[hr_drop_threshold]}
    hr_drop_minutes=${setting[hr_drop_minutes]}
    tg_summary_time=${setting[tg_summary_time]}

    local notify_webhooks ntfy_url ntfy_token notify_tor
    notify_webhooks=${setting[notify_webhooks]}
    ntfy_url=${setting[ntfy_url]}
    ntfy_token=${setting[ntfy_token]}
    notify_tor=${setting[notify_tor]}

    local tari_mem_limit ram_mb huge_mb avail_mb reserve_mb monero_mem_limit
    if [ "$TARI_MODE" != "local" ]; then
        tari_mem_limit="0m"
    else
        tari_mem_limit=${setting[tari_mem_limit]}
        case "$tari_mem_limit" in
        "" | auto)
            huge_mb=0
            if [ "$OS_TYPE" == "Darwin" ]; then
                ram_mb=$(($(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1048576))
            else
                ram_mb=$(awk '/MemTotal/ {print int($2/1024)}' "${PITHEAD_MEMINFO:-/proc/meminfo}" 2>/dev/null || echo 0)
                huge_mb=$(hugepages_carveout_mb)
            fi
            [ "${ram_mb:-0}" -gt 0 ] 2>/dev/null || ram_mb=16384
            [ "${huge_mb:-0}" -ge 0 ] 2>/dev/null || huge_mb=0
            avail_mb=$((ram_mb - huge_mb))
            [ "$avail_mb" -lt 2048 ] && avail_mb=2048
            reserve_mb=$((avail_mb / 4))
            [ "$reserve_mb" -lt 2048 ] && reserve_mb=2048
            tari_mem_limit=$((avail_mb - reserve_mb))
            [ "$tari_mem_limit" -lt 2048 ] && tari_mem_limit=2048
            tari_mem_limit="${tari_mem_limit}m"
            ;;
        esac
    fi

    monero_mem_limit=${setting[monero_mem_limit]}
    case "$monero_mem_limit" in "" | auto) monero_mem_limit="6g" ;; esac

    log "Monero block-prep threads: $prep_threads | pool: $pool_type | mode: $MONERO_MODE"

    local tari_secret_file="$PWD/data/tari-wallet-secret.env" tari_secret_tmp tari_foreign tari_secret_ok=false
    local tari_secret_target="${2:-$tari_secret_file}"
    if [ "$target" != "$PITHEAD_ENV_DRYRUN" ]; then
        mkdir -p "$PWD/data"
        tari_secret_tmp=$(umask 077 && mktemp "$PWD/data/.tari-wallet-secret.XXXXXX") || error "Could not create a temp file in $PWD/data."
        printf 'MINOTARI_WALLET_VIEW_PRIVATE_KEY=%s\nMINOTARI_WALLET_SPEND_KEY=%s\nMINOTARI_WALLET_PASSWORD=%s\n' \
            "$TARI_VIEW_KEY" "$TARI_SPEND_PUBLIC_KEY" "$TARI_WALLET_PASSWORD" >"$tari_secret_tmp" &&
            tari_foreign=$(find "$tari_secret_tmp" -maxdepth 0 ! -uid "$APP_UID" -print) &&
            { [ -z "$tari_foreign" ] || chown "$APP_UID:$APP_GID" "$tari_secret_tmp" 2>/dev/null || sudo chown "$APP_UID:$APP_GID" "$tari_secret_tmp"; } &&
            mv -fT -- "$tari_secret_tmp" "$tari_secret_target" && tari_secret_ok=true
        # An owner that cannot be checked or corrected keeps the previous file, and fails an enabled wallet.
        [ "$tari_secret_ok" = true ] || { rm -f "$tari_secret_tmp" && [ "$tari_secret_target" = "$tari_secret_file" ] && [ "${TARI_PAYOUT_CONFIRM_ENABLED:-false}" != true ]; } ||
            error "Could not write $tari_secret_file owned by uid $APP_UID for the Tari payout wallet; the previous file is kept."
    fi

    (
        umask 077
        cat <<EOF >"$target"
MONERO_DATA_DIR=$(dotenv_render_value "$MONERO_DIR")
TARI_DATA_DIR=$(dotenv_render_value "$TARI_DIR")
P2POOL_DATA_DIR=$(dotenv_render_value "$P2POOL_DIR")
DASHBOARD_DATA_DIR=$(dotenv_render_value "$DASHBOARD_DIR")
TOR_DATA_DIR=$(dotenv_render_value "$TOR_DATA_DIR")
MONERO_NODE_USERNAME=$(dotenv_render_value "$MONERO_USER")
MONERO_NODE_PASSWORD=$(dotenv_render_value "$MONERO_PASS")
P2POOL_BACKUP_ARGS_B64=$(dotenv_render_value "$(monero_backup_args)")
MONERO_BACKUP_NODES=$(dotenv_render_value "$(jq -c '.monero.backup_nodes // []' "$CONFIG_FILE")")
MONERO_WALLET_ADDRESS=$(dotenv_render_value "$MONERO_WALLET")
MONERO_VIEW_KEY=$(dotenv_render_value "$MONERO_VIEW_KEY")
PAYOUT_SCAN_HEIGHT=$(dotenv_render_value "$PAYOUT_SCAN_HEIGHT")
PAYOUT_CONFIRM_ENABLED=$(dotenv_render_value "$PAYOUT_CONFIRM_ENABLED")
WALLET_RPC_USERNAME=wallet
WALLET_RPC_PASSWORD=$(dotenv_render_value "$WALLET_RPC_PASSWORD")
MONERO_WALLET_RPC_URL=http://127.0.0.1:18082/json_rpc
TARI_WALLET_ADDRESS=$(dotenv_render_value "${TARI_WALLET:-your_tari_wallet_address}")
TARI_VIEW_KEY=$(dotenv_render_value "$TARI_VIEW_KEY")
TARI_SPEND_PUBLIC_KEY=$(dotenv_render_value "$TARI_SPEND_PUBLIC_KEY")
TARI_WALLET_PASSWORD=$(dotenv_render_value "$TARI_WALLET_PASSWORD")
TARI_WALLET_BIRTHDAY=$(dotenv_render_value "$TARI_WALLET_BIRTHDAY")
TARI_PAYOUT_CONFIRM_ENABLED=$(dotenv_render_value "$TARI_PAYOUT_CONFIRM_ENABLED")
TARI_WALLET_GRPC_ADDRESS=127.0.0.1:18143
TARI_WALLET_SECRET_FILE=$(dotenv_render_value "$tari_secret_file")
MONERO_ONION_ADDRESS=$(dotenv_render_value "$MONERO_ONION")
TARI_ONION_ADDRESS=$(dotenv_render_value "$TARI_ONION")
P2POOL_ONION_ADDRESS=$(dotenv_render_value "$P2POOL_ONION")
DASHBOARD_ONION_ADDRESS=$(dotenv_render_value "$DASHBOARD_ONION")
DASHBOARD_ONION_CLIENT_PUBKEY=$(dotenv_render_value "$DASHBOARD_ONION_CLIENT_PUBKEY")
DASHBOARD_ONION_CLIENT_PRIVKEY=$(dotenv_render_value "$DASHBOARD_ONION_CLIENT_PRIVKEY")
PITHEAD_PROFILE=$(dotenv_render_value "$profile")
P2POOL_FLAGS=$(dotenv_render_value "$p2pool_flags")
P2POOL_PORT=$(dotenv_render_value "$p2pool_port")
STRATUM_BIND=$(dotenv_render_value "$STRATUM_BIND")
STRATUM_PORT=$(dotenv_render_value "$STRATUM_PORT")
PROXY_STRATUM_PASSWORD=$(dotenv_render_value "$STRATUM_PASSWORD")
PROXY_STRATUM_TLS=$(dotenv_render_value "$STRATUM_TLS")
STRATUM_TLS_FINGERPRINT=$(dotenv_render_value "$(stratum_tls_fingerprint)")
PROXY_TLS_DIR=$(dotenv_render_value "$PROXY_TLS_DIR")
XVB_POOL_URL=$(dotenv_render_value "$xvb_url")
XVB_DONOR_ID=$(dotenv_render_value "$xvb_donor")
XVB_ENABLED=$(dotenv_render_value "$xvb_enabled")
XVB_TOR_ENABLED=$(dotenv_render_value "$xvb_tor")
DONATION_ENABLED=$(dotenv_render_value "$donation_enabled")
DONATION_PERCENT=$(dotenv_render_value "$donation_percent")
DONATION_TOR_ENABLED=$(dotenv_render_value "$donation_tor")
XVB_DONATION_LEVEL=$(dotenv_render_value "$xvb_donation_level")
TARI_REQUIRED=$(dotenv_render_value "$tari_required")
DASHBOARD_FAIL_CLOSED=$(dotenv_render_value "$fail_closed")
DASHBOARD_CHECK_UPDATES=$(dotenv_render_value "$check_for_updates")
TARI_MEM_LIMIT=$(dotenv_render_value "$tari_mem_limit")
HEALTHCHECKS_PING_URL=$(dotenv_render_value "$hc_ping_url")
XVB_STANDBY_SOURCE=$(dotenv_render_value "$xvb_standby_source")
TELEGRAM_LEVEL=$(dotenv_render_value "$tg_level")
TELEGRAM_BOT_TOKEN=$(dotenv_render_value "$tg_token")
TELEGRAM_CHAT_ID=$(dotenv_render_value "$tg_chat")
TELEGRAM_COMMANDS_ENABLED=$(dotenv_render_value "$tg_commands")
HASHRATE_DROP_THRESHOLD_PCT=$(dotenv_render_value "$hr_drop_threshold")
HASHRATE_DROP_MINUTES=$(dotenv_render_value "$hr_drop_minutes")
TELEGRAM_DAILY_SUMMARY_TIME=$(dotenv_render_value "$tg_summary_time")
NOTIFY_WEBHOOK_URLS=$(dotenv_render_value "$notify_webhooks")
NTFY_URL=$(dotenv_render_value "$ntfy_url")
NTFY_TOKEN=$(dotenv_render_value "$ntfy_token")
NOTIFY_TOR=$(dotenv_render_value "$notify_tor")
MONERO_MEM_LIMIT=$(dotenv_render_value "$monero_mem_limit")
P2POOL_URL=$(dotenv_render_value "${NETWORK_PREFIX}.28:3333")
NETWORK_SUBNET=$(dotenv_render_value "$NETWORK_SUBNET")
NETWORK_PREFIX=$(dotenv_render_value "$NETWORK_PREFIX")
TOR_EGRESS_FIREWALL=$(dotenv_render_value "$TOR_EGRESS_FIREWALL")
TOR_AUTO_HEAL=$(dotenv_render_value "$TOR_AUTO_HEAL")
TARI_EXPLORER_URL=$(dotenv_render_value "$TARI_EXPLORER_URL")
P2POOL_CLEARNET=$(dotenv_render_value "$P2POOL_CLEARNET")
PROXY_API_PORT=3344
PROXY_AUTH_TOKEN=$(dotenv_render_value "$PROXY_AUTH_TOKEN")
XMRIG_API_PORT=$(dotenv_render_value "$worker_api_port")
XMRIG_API_AUTH=$(dotenv_render_value "$worker_api_auth")
XMRIG_API_TOKEN=$(dotenv_render_value "$worker_api_token")
WORKER_API_TOKENS=$(dotenv_render_value "$worker_api_tokens_json")
PROXY_DONATE_LEVEL=$(dotenv_render_value "$DONATE_LEVEL")
MONERO_PRUNE=$(dotenv_render_value "$prune")
MONERO_CLEARNET_SYNC=$(dotenv_render_value "$monero_clearnet")
TARI_CLEARNET_SYNC=$(dotenv_render_value "$tari_clearnet")
CLEARNET_STATE_DIR=$(dotenv_render_value "$CLEARNET_STATE_DIR")
MONERO_PREP_THREADS=$(dotenv_render_value "$prep_threads")
MONERO_OUT_PEERS=$(dotenv_render_value "$out_peers")
MONERO_RPC_BIND=$(dotenv_render_value "$rpc_bind")
MONERO_ZMQ_BIND=$(dotenv_render_value "$zmq_bind")
MONERO_NODE_HOST=$(dotenv_render_value "$mono_host")
MONERO_RPC_URL=$(dotenv_render_value "$mono_rpc_url")
MONERO_RPC_PORT=$(dotenv_render_value "$rpc_port")
MONERO_ZMQ_PORT=$(dotenv_render_value "$zmq_port")
TARI_MODE=$(dotenv_render_value "$TARI_MODE")
TARI_GRPC_ADDRESS=$(dotenv_render_value "$tari_grpc_addr")
TARI_GRPC_BIND=$(dotenv_render_value "$tari_grpc_bind")
COMPOSE_PROJECT_NAME=$(dotenv_render_value "$project")
COMPOSE_PROFILES=$(dotenv_render_value "$profiles")
TOR_COMPOSE_PROFILES=$(dotenv_render_value "$tor_profiles")
DASHBOARD_SECURE=$(dotenv_render_value "$DASHBOARD_SECURE")
DASHBOARD_EXPOSE_PUBLIC_IP=$(dotenv_render_value "$DASHBOARD_EXPOSE_PUBLIC_IP")
DASHBOARD_ONION_ENABLED=$(dotenv_render_value "$DASHBOARD_ONION_ENABLED")
DASHBOARD_ONION_CLIENT_AUTH=$(dotenv_render_value "$DASHBOARD_ONION_CLIENT_AUTH")
DASHBOARD_TZ=$(dotenv_render_value "$DASHBOARD_TZ")
DASHBOARD_AUTH_USER=$(dotenv_render_value "$DASHBOARD_AUTH_USER")
DASHBOARD_AUTH_HASH_B64=$(dotenv_render_value "$DASHBOARD_AUTH_HASH_B64")
DASHBOARD_AUTH_PW_FP=$(dotenv_render_value "$DASHBOARD_AUTH_PW_FP")
DASHBOARD_CONTROL_ENABLED=$(dotenv_render_value "$DASHBOARD_CONTROL_ENABLED")
DASHBOARD_MODE=$(dotenv_render_value "$DASHBOARD_MODE")
PITHEAD_DIAG_CONTAINERS=$(dotenv_render_value "${PITHEAD_DIAG_CONTAINERS// /,}")
CONTROL_DIR=$(dotenv_render_value "$CONTROL_DIR")
CADDY_LOG_DIR=$(dotenv_render_value "$CADDY_LOG_DIR")
HOST_IP=$(dotenv_render_value "$HOST_IP")
PITHEAD_TLS_DIR=$(dotenv_render_value "$(appliance_tls_dir)")
HOST_PORT=$(dotenv_render_value "$HOST_PORT")
DEPLOYMENT_COMPLETED=$(dotenv_render_value "${DEPLOYMENT_COMPLETED:-false}")
EOF
        [ "${PAYOUT_NODE_REMOTE:-false}" != true ] ||
            printf 'PAYOUT_NODE_REMOTE=true\nPAYOUT_NODE_PROXY=%s\n' "$(dotenv_render_value "${PAYOUT_NODE_PROXY:-}")" >>"$target"
    )
    chmod 600 "$target"
}
