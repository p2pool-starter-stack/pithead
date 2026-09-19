# Notification change descriptions stay separate from the stack/runtime cases in 39.
describe_notification_change() { # <key> <old> <new>; sets caller's flag/msg
    local key="$1" old="$2" new="$3"
    case "$key" in
    TELEGRAM_ENABLED)
        msg="Telegram operator bot → $([ "$new" == "true" ] && echo on || echo off) — the dashboard container is recreated."
        ;;
    TELEGRAM_BOT_TOKEN)
        # Secret — never echo the token value into the change preview / logs.
        msg="Telegram bot token updated — the dashboard container is recreated."
        ;;
    TELEGRAM_CHAT_ID) msg="Telegram chat id: $old → $new." ;;
    TELEGRAM_COMMANDS_ENABLED)
        msg="Telegram command interface → $([ "$new" == "true" ] && echo on || echo off) — the bot $([ "$new" == "true" ] && echo "now answers" || echo "no longer answers") /status, /hashrate, /workers, /sync from the configured chat; the dashboard container is recreated."
        ;;
    TELEGRAM_EVENT_*) msg="Telegram alert toggle ($key): $old → $new." ;;
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
