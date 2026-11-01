package preview

import "fmt"

func describeNotification(key, old, new string) (Change, bool) {
	switch key {
	case "TELEGRAM_ENABLED":
		if new == "true" {
			return change("INFO", "Telegram operator bot → on — the dashboard container is recreated."), true
		}
		return change("INFO", "Telegram operator bot → off — every Telegram alert stops, the wallet-change and clearnet-exposure tamper alarms included; the dashboard container is recreated."), true
	case "TELEGRAM_BOT_TOKEN":
		return change("INFO", "Telegram bot token updated — a wrong token stops every Telegram alert, the wallet-change and clearnet-exposure alarms included, and another bot's token sends them to that bot's owner; the dashboard container is recreated."), true
	case "TELEGRAM_CHAT_ID":
		return change("INFO", fmt.Sprintf("Telegram chat id: %s → %s — a wrong id stops delivery or sends every alert, payout and wallet-change ones included, to another chat.", old, new)), true
	case "TELEGRAM_COMMANDS_ENABLED":
		if new == "true" {
			return change("INFO", "Telegram command interface → on — the bot now answers /status, /hashrate, /workers, /sync from the configured chat; the dashboard container is recreated."), true
		}
		return change("INFO", "Telegram command interface → off — the bot no longer answers /status, /hashrate, /workers, /sync from the configured chat; the dashboard container is recreated."), true
	case "TELEGRAM_EVENT_WALLET_CHANGED", "TELEGRAM_EVENT_CLEARNET_EXPOSED":
		if new == "false" {
			if key == "TELEGRAM_EVENT_WALLET_CHANGED" {
				return change("DEST", "Wallet-change alarm OFF — a payout-address change will no longer alert Telegram; a wallet swap could go unnoticed."), true
			}
			return change("DEST", "Clearnet-exposure alarm OFF — a node exposing this machine's IP over clearnet will no longer alert Telegram."), true
		}
		return change("INFO", key[len("TELEGRAM_EVENT_"):]+" Telegram alarm → on."), true
	case "TELEGRAM_DAILY_SUMMARY_TIME":
		return change("INFO", fmt.Sprintf("Telegram daily summary time: %s → %s (local time).", old, new)), true
	case "NOTIFY_WEBHOOK_URLS":
		return describeSink(old, new, "Webhook alert sink(s) DISABLED — URL list cleared; the dashboard container is recreated.", "Webhook alert sink(s) ENABLED — every alert now also POSTs as JSON to the configured URL(s), over Tor by default; the dashboard container is recreated.", "Webhook alert URL(s) updated — the dashboard container is recreated."), true
	case "NTFY_URL":
		return describeSink(old, new, "ntfy alert sink DISABLED — topic URL cleared; the dashboard container is recreated.", "ntfy alert sink ENABLED — every alert now also POSTs to the configured ntfy topic, over Tor by default; the dashboard container is recreated.", "ntfy topic URL updated — the dashboard container is recreated."), true
	case "NTFY_TOKEN":
		return change("INFO", "ntfy access token updated — the dashboard container is recreated."), true
	case "NOTIFY_TOR":
		if new == "true" {
			return change("INFO", "Webhook/ntfy alerts back on Tor — endpoints see a Tor exit, not this host's IP; the dashboard container is recreated."), true
		}
		return change("INFO", "⚠ Webhook/ntfy alerts OFF Tor — POSTs go out directly, so clearnet endpoints see this host's IP (the LAN/self-hosted carve-out; Tor exits can't reach private addresses); the dashboard container is recreated."), true
	}
	if len(key) >= len("TELEGRAM_EVENT_") && key[:len("TELEGRAM_EVENT_")] == "TELEGRAM_EVENT_" {
		return change("INFO", fmt.Sprintf("Telegram alert toggle (%s): %s → %s.", key, old, new)), true
	}
	return Change{}, false
}

func describeExposure(key, new string) (Change, bool) {
	switch key {
	case "TOR_EGRESS_FIREWALL":
		if new == "false" {
			return change("CONFIRM", "⚠ Tor-only egress firewall DISABLED — the host rules that drop direct clearnet dials from monerod, p2pool, tari and xmrig-proxy are removed, so a misconfigured or buggy daemon can reach the internet directly and show this host's IP to whatever it dials; each daemon's own Tor setting becomes the only guard."), true
		}
		return change("INFO", "Tor-only egress firewall ENABLED — unselected mining containers' direct clearnet dials are dropped; only Tor and containers explicitly opted into clearnet can reach the public internet."), true
	case "XVB_TOR_ENABLED":
		if new == "false" {
			return Change{}, false
		}
		return change("INFO", "XvB donation mining back on Tor — the XvB pool sees a Tor exit, not this host's IP."), true
	case "DASHBOARD_EXPOSE_PUBLIC_IP":
		if new == "true" {
			return change("CONFIRM", "⚠ Dashboard PUBLISHED on this machine's globally-routable addresses — on a network that passes IPv6 through, anyone on the internet can reach the dashboard login; those addresses are no longer kept out of the site list and listener, so only the login and your own protection guard it."), true
		}
		return change("INFO", "Dashboard back to LAN, ULA and loopback addresses only — globally-routable addresses leave its site list and listener."), true
	case "P2POOL_CLEARNET":
		if new == "true" {
			return Change{}, false
		}
		return change("INFO", "P2Pool sidechain peers back on Tor — outbound dials go through the bundled Tor proxy and clearnet seed-node DNS stays off."), true
	}
	return Change{}, false
}

func describeSink(old, new, disabled, enabled, updated string) Change {
	if new == "" {
		return change("INFO", disabled)
	}
	if old == "" {
		return change("INFO", enabled)
	}
	return change("INFO", updated)
}
