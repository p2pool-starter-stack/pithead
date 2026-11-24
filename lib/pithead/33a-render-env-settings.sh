render_env_settings() {
    config_defaults_json | jq -r --arg platform "$(config_platform)" --slurpfile cfg "$CONFIG_FILE" '
        (.values * (if $platform == "appliance" then .appliance else {} end)) as $defaults
        | .profiles[$cfg[0].profile // "balance"] as $profile
        | def bool($path; $value): (if $profile | has($path) then $profile[$path] else $value end) as $fallback
            | getpath($path | split(".")) | if . == null then $fallback else . end;
        def get($path): bool($path; $defaults | getpath($path | split(".")));
        $cfg[0] | {
            tari_grpc_lan: (.tari.grpc_lan_access // false),
            monero_clearnet: bool("monero.clearnet_initial_sync"; false),
            tari_clearnet: bool("tari.clearnet_initial_sync"; false),
            prep_threads: (.monero.prep_blocks_threads // "auto"),
            out_peers: (.monero.out_peers // 48),
            rpc_lan: (.monero.rpc_lan_access // false),
            zmq_lan: (.monero.zmq_lan_access // false),
            pool_type: (.p2pool.pool // "mini"),
            p2pool_clearnet: bool("p2pool.clearnet"; false),
            xvb_enabled: get("xvb.enabled"),
            xvb_tor: bool("xvb.tor"; true),
            xvb_url: (.xvb.url // ""),
            xvb_donor: (.xvb.donor_id // ""),
            xvb_donation_level: (.xvb.donation_level // ""),
            donation_enabled: get("donation.enabled"),
            donation_percent: get("donation.percent"),
            donation_tor: get("donation.tor"),
            tari_required: get("dashboard.tari_required"),
            fail_closed: bool("dashboard.fail_closed"; false),
            hc_ping_url: (.healthchecks.ping_url // ""),
            xvb_standby_source: (.xvb.standby.source // ""),
            check_for_updates: (if .dashboard.check_for_updates == false then "false" else "true" end),
            worker_api_port: (.workers.api_port // 8080),
            worker_api_auth: get("workers.api_auth"),
            worker_api_token: get("workers.api_token"),
            tg_level: (.telegram.level // "off"),
            tg_token: (.telegram.bot_token // ""),
            tg_chat: (.telegram.chat_id // ""),
            tg_commands: (if .telegram.commands.enabled != null then .telegram.commands.enabled | tostring else "false" end),
            hr_drop_threshold: (.dashboard.hashrate_drop_threshold // 50),
            hr_drop_minutes: (.dashboard.hashrate_drop_minutes // 10),
            tg_summary_time: (.telegram.daily_summary_time // "08:00"),
            notify_webhooks: ((.notifications.webhooks // []) | join(" ")),
            ntfy_url: (.notifications.ntfy.url // ""),
            ntfy_token: (.notifications.ntfy.token // ""),
            notify_tor: bool("notifications.tor"; true),
            tari_mem_limit: (.tari.mem_limit // "auto"),
            monero_mem_limit: (.monero.mem_limit // "auto")
        } | to_entries[] | "\(.key)\t\(.value)"'
}
