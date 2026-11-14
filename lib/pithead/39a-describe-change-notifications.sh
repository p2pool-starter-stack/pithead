# Notification change descriptions stay separate from the stack/runtime cases in 39.
telegram_level_events() {
    local critical="node_down node_recovered container_unhealthy db_unhealthy disk_space hashrate_loss"
    local important="$critical worker_offline worker_recovered sync_finished db_reset xvb_no_share xvb_registration hashrate_low high_reject_rate hugepages low_ram payout_found payout_confirmed raffle_win"
    case "${1:-}" in
    "" | off) echo "" ;;
    critical) echo "$critical" ;;
    important) echo "$important" ;;
    *) echo "$important worker_joined worker_left stack_online daily_summary block_found new_release" ;;
    esac
}

telegram_level_change_message() {
    local old_events new_events e started="" stopped=""
    old_events=" $(telegram_level_events "$1") "
    new_events=" $(telegram_level_events "$2") "
    for e in $new_events; do
        case "$old_events" in *" $e "*) ;; *) started="$started ${e}," ;; esac
    done
    for e in $old_events; do
        case "$new_events" in *" $e "*) ;; *) stopped="$stopped ${e}," ;; esac
    done
    msg="Telegram alert level: ${1:-off} → ${2:-off}."
    [ -z "$started" ] || msg="$msg Starts:${started%,}."
    [ -z "$stopped" ] || msg="$msg Stops:${stopped%,}."
    msg="$msg The wallet-change, clearnet-exposure and payout-wallet alarms stay on at every level; the dashboard container is recreated."
}

describe_notification_change() { # <key> <old> <new>; sets caller's flag/msg
    local key="$1" old="$2" new="$3"
    case "$key" in
    TELEGRAM_LEVEL)
        telegram_level_change_message "$old" "$new"
        ;;
    TELEGRAM_BOT_TOKEN)
        # Secret — never echo the token value into the change preview / logs. #2367: name the cost.
        msg="Telegram bot token updated — a wrong token stops every Telegram alert, the wallet-change and clearnet-exposure alarms included, and another bot's token sends them to that bot's owner; the dashboard container is recreated."
        ;;
    TELEGRAM_CHAT_ID)
        msg="Telegram chat id: $old → $new — a wrong id stops delivery or sends every alert, payout and wallet-change ones included, to another chat."
        ;;
    TELEGRAM_COMMANDS_ENABLED)
        msg="Telegram command interface → $([ "$new" == "true" ] && echo on || echo off) — the bot $([ "$new" == "true" ] && echo "now answers" || echo "no longer answers") /status, /hashrate, /workers, /sync from the configured chat; the dashboard container is recreated."
        ;;
    TELEGRAM_DAILY_SUMMARY_TIME) msg="Telegram daily summary time: $old → $new (local time)." ;;
    NOTIFY_WEBHOOK_URLS)
        # Webhook URLs often carry tokens in the query string — report the change WITHOUT values.
        if [ -z "$new" ]; then
            msg="Webhook alert sink(s) DISABLED — URL list cleared; the dashboard container is recreated."
        elif [ -z "$old" ]; then
            msg="Webhook alert sink(s) ENABLED — every alert now also POSTs as JSON to the configured URL(s), over Tor by default; the dashboard container is recreated."
        else
            msg="Webhook alert URL(s) updated — the dashboard container is recreated."
        fi
        ;;
    NTFY_URL)
        # The topic URL is a capability secret (whoever knows it can read/post the topic).
        if [ -z "$new" ]; then
            msg="ntfy alert sink DISABLED — topic URL cleared; the dashboard container is recreated."
        elif [ -z "$old" ]; then
            msg="ntfy alert sink ENABLED — every alert now also POSTs to the configured ntfy topic, over Tor by default; the dashboard container is recreated."
        else
            msg="ntfy topic URL updated — the dashboard container is recreated."
        fi
        ;;
    NTFY_TOKEN) msg="ntfy access token updated — the dashboard container is recreated." ;;
    NOTIFY_TOR)
        if [ "$new" == "true" ]; then
            msg="Webhook/ntfy alerts back on Tor — endpoints see a Tor exit, not this host's IP; the dashboard container is recreated."
        else
            msg="⚠ Webhook/ntfy alerts OFF Tor — POSTs go out directly, so clearnet endpoints see this host's IP (the LAN/self-hosted carve-out; Tor exits can't reach private addresses); the dashboard container is recreated."
        fi
        ;;
    *) return 1 ;;
    esac
}
