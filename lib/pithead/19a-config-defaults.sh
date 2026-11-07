# shellcheck shell=bash
config_defaults_json() {
    cat <<'PITHEAD_DEFAULTS_JSON'
{"values":{"config_version":"2.0.0","p2pool":{"pool":"mini","stratum_bind":"0.0.0.0","stratum_port":3333,"stratum_password":"","stratum_tls":false,"clearnet":false,"data_dir":"auto"},"proxy":{"donate_level":0},"local_miner":{"enabled":false},"xvb":{"enabled":false,"url":"na.xmrvsbeast.com:4247","donor_id":"auto","donation_level":"auto","tor":true,"standby":{"source":""}},"monero":{"wallet_address":"your_monero_wallet_address","view_key":"","payout_scan_height":"auto","mode":"local","node_username":"","node_password":"","prune":true,"clearnet_initial_sync":false,"rpc_lan_access":false,"zmq_lan_access":false,"remote":{"host":"node.remote-monero-host.com","rpc_port":18081,"zmq_port":18083},"prep_blocks_threads":"auto","out_peers":48,"data_dir":"auto","mem_limit":"auto","backup_nodes":[]},"tari":{"wallet_address":"your_tari_wallet_address","view_key":"","spend_public_key":"","payout_scan_birthday":"auto","mode":"off","grpc_lan_access":false,"clearnet_initial_sync":false,"remote":{"host":"tari-node.example","grpc_port":18142},"data_dir":"auto","mem_limit":"auto","explorer_url":"https://textexplore.tari.com/?json"},"workers":{"api_port":8080,"api_auth":"none","api_token":"","list":[]},"dashboard":{"secure":true,"host":"auto","expose_public_ip":false,"port":"auto","timezone":"auto","auth":{"username":"admin","password":""},"onion":{"enabled":false,"client_auth":true},"control":{"enabled":false},"energy":{"cost_per_kwh":0,"currency":"USD","price_feed":false,"tari_price":0,"xmr_price":0},"hashrate_drop_threshold":50,"hashrate_drop_minutes":10,"tari_required":false,"fail_closed":false,"check_for_updates":true,"data_dir":"auto"},"healthchecks":{"ping_url":""},"telegram":{"enabled":false,"bot_token":"","chat_id":"","events":{"node_down":true,"node_recovered":true,"worker_offline":true,"worker_recovered":true,"worker_joined":true,"worker_left":true,"sync_finished":true,"disk_space":true,"db_unhealthy":true,"db_reset":true,"xvb_no_share":true,"clearnet_exposed":true,"xvb_registration":true,"new_release":true,"stack_online":true,"daily_summary":true,"hashrate_low":true,"hashrate_loss":true,"hugepages":true,"low_ram":true,"wallet_changed":true,"high_reject_rate":true,"block_found":true,"payout_found":true,"payout_confirmed":true,"container_unhealthy":true,"raffle_win":true},"daily_summary_time":"08:00","commands":{"enabled":false}},"notifications":{"webhooks":[],"ntfy":{"url":"","token":""},"tor":true},"tor":{"data_dir":"auto","auto_heal":false},"network":{"subnet":"172.28.0.0/24","tor_egress_firewall":true}},"appliance":{"dashboard":{"host":"pithead","control":{"enabled":true}},"local_miner":{"enabled":true},"tor":{"auto_heal":true}},"materialize":["tari.mode","xvb.enabled","dashboard.tari_required","dashboard.host","local_miner.enabled"],"LEGACY_ABSENT":[{"path":"tari.mode","value":"local"},{"path":"xvb.enabled","value":true},{"path":"dashboard.tari_required","value":true},{"path":"local_miner.enabled","platform":"appliance","value":false},{"path":"dashboard.host","platform":"appliance","value":"auto"}]}
PITHEAD_DEFAULTS_JSON
}

config_platform() {
    if is_appliance; then printf appliance; else printf diy; fi
}

config_defaults() {
    local platform mode="${1:-new}"
    platform="${2:-$(config_platform)}"
    config_defaults_json | jq --arg platform "$platform" --arg mode "$mode" '
        . as $table | (.values * (if $platform == "appliance" then .appliance else {} end))
        | if $mode == "legacy" then
            reduce $table.LEGACY_ABSENT[] as $entry (.;
                if ($entry.platform // $platform) == $platform
                then setpath($entry.path | split("."); $entry.value) else . end)
          else . end'
}

default_of() {
    config_defaults "${2:-new}" | jq -r --arg path "${1#.}" 'getpath($path | split(".")) | if . == null then error("unknown default") else . end'
}

new_install_defaults() {
    local defaults
    defaults=$(config_defaults)
    config_defaults_json | jq --argjson defaults "$defaults" '
        reduce (.materialize + ["monero.clearnet_initial_sync", "tari.clearnet_initial_sync"])[] as $path
            ({}; setpath($path | split("."); $defaults | getpath($path | split("."))))'
}

config_get() {
    local fallback
    fallback=$(config_defaults legacy | jq -c --arg path "${1#.}" 'getpath($path | split("."))') || return 1
    jq -r --argjson fallback "$fallback" --arg path "${1#.}" '
        getpath($path | split(".")) | if . == null then $fallback else . end' "${2:-$CONFIG_FILE}"
}
