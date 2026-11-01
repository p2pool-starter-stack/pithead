package preview

import (
	"fmt"
	"strings"
)

func describeStackMore(key, old, new string) (Change, bool) {
	switch key {
	case "TARI_REQUIRED":
		if new == "true" {
			return change("INFO", "Tari → required — a 15-minute Tari RPC outage rejects workers (startup, migration and syncing only alert), the miner waits for Tari's sync, and a Tari-only sync takes over the dashboard."), true
		}
		return change("INFO", "Tari → non-blocking — keep mining Monero through a Tari outage, start as soon as Monero is synced, and keep the operational dashboard while Tari syncs."), true
	case "DASHBOARD_FAIL_CLOSED":
		if new == "true" {
			return change("INFO", "Fail-closed ENABLED — an unrecoverable dashboard health failure (DB recovery itself failing, or the dashboard container crash-looping) now HOLDS p2pool and xmrig-proxy until it clears, instead of only alerting."), true
		}
		return change("INFO", "Fail-closed DISABLED — an unrecoverable dashboard health failure now only alerts (Telegram/Healthchecks + badge); mining is never held for it."), true
	case "DASHBOARD_CHECK_UPDATES":
		if new == "true" {
			return change("INFO", "Dashboard update check ENABLED — the dashboard will check GitHub (over Tor) for a newer release and show a link badge; the dashboard container is recreated."), true
		}
		return change("INFO", "Dashboard update check DISABLED — the dashboard no longer contacts GitHub; the dashboard container is recreated."), true
	case "TARI_MEM_LIMIT":
		return change("INFO", fmt.Sprintf("Tari memory cap: %s → %s — the tari container is recreated (brief restart; on-disk chain data is preserved).", old, new)), true
	case "MONERO_MEM_LIMIT":
		return change("INFO", fmt.Sprintf("Monero memory cap: %s → %s — the monerod container is recreated (brief restart; the blockchain on disk is preserved).", old, new)), true
	case "DASHBOARD_SECURE":
		scheme := "HTTP"
		if new == "true" {
			scheme = "HTTPS"
		}
		return change("INFO", fmt.Sprintf("Dashboard scheme → %s (secure=%s).", scheme, new)), true
	case "DASHBOARD_AUTH_HASH_B64":
		if new == "" {
			return change("INFO", "Dashboard login DISABLED — the dashboard is reachable without a password again."), true
		}
		if old == "" {
			return change("DEST", "Dashboard login ENABLED — Caddy now requires the configured username/password: a mistyped password locks this session out, and on the appliance it is also the console root login; the caddy container is recreated."), true
		}
		return change("DEST", "Dashboard login password CHANGED — other signed-in sessions are logged out, a mistyped password locks this session out, and on the appliance it is also the console root login; the caddy container is recreated."), true
	case "DASHBOARD_AUTH_USER":
		return change("INFO", fmt.Sprintf("Dashboard login username: %s → %s.", old, new)), true
	case "DASHBOARD_AUTH_PW_FP", "CLEARNET_STATE_DIR", "CONTROL_DIR", "CADDY_LOG_DIR", "DASHBOARD_ONION_ADDRESS", "DASHBOARD_ONION_CLIENT_PUBKEY", "DASHBOARD_ONION_CLIENT_PRIVKEY", "MONERO_RPC_URL", "WALLET_RPC_USERNAME", "MONERO_WALLET_RPC_URL", "TARI_WALLET_GRPC_ADDRESS", "TARI_WALLET_SECRET_FILE":
		return change("INFO", ""), true
	case "DASHBOARD_CONTROL_ENABLED":
		if new == "true" {
			return change("DEST", "Dashboard configuration editing ENABLED — the dashboard can stage config changes that a host-side runner validates and applies; the dashboard container is recreated."), true
		}
		return change("INFO", "Dashboard configuration editing disabled — the control runner units are removed; the dashboard container is recreated."), true
	case "DASHBOARD_ONION_ENABLED":
		if new == "true" {
			return change("DEST", "Dashboard Tor onion ENABLED — the dashboard is published as a hidden service reachable over Tor; tor and caddy are recreated."), true
		}
		return change("DEST", "Dashboard Tor onion DISABLED — the onion is withdrawn; tor and caddy are recreated."), true
	case "DASHBOARD_ONION_CLIENT_AUTH":
		if new == "true" {
			return change("INFO", "Dashboard onion client-auth → ON — the onion won't respond without your client key."), true
		}
		return change("INFO", "Dashboard onion client-auth → OFF — the onion is password-only."), true
	case "HOST_IP":
		return change("APPROVAL", fmt.Sprintf("Dashboard hostname: %s → %s.", old, new)), true
	case "HOST_PORT":
		if old == "" && new == "" {
			return change("INFO", ""), true
		}
		return change("INFO", fmt.Sprintf("Dashboard Caddy port: %s → %s — the caddy container is recreated.", defaultText(old, "default (443/80)"), defaultText(new, "default (443/80)"))), true
	case "MONERO_PREP_THREADS":
		return change("INFO", fmt.Sprintf("Monero block-prep threads: %s → %s.", old, new)), true
	case "MONERO_OUT_PEERS":
		return change("CONFIRM", fmt.Sprintf("Monero outbound peer target: %s → %s — monerod restarts; over Tor each outbound peer is roughly one circuit.", old, new)), true
	case "HEALTHCHECKS_PING_URL":
		return describeHealthchecks(old, new), true
	case "TOR_AUTO_HEAL":
		if new != "true" {
			return Change{}, false
		}
		return change("INFO", "Tor egress self-heal ENABLED — when clearnet egress through Tor stays broken for 15 min, the dashboard tries two NEWNYM circuit refreshes before one container restart (max 3 actions per outage, 30-min cooldown; only the restart drops mining connections); the dashboard container is recreated."), true
	case "XMRIG_API_TOKEN", "XVB_STANDBY_SOURCE", "WORKER_API_TOKENS":
		return change("INFO", "Secret configuration value updated — the dashboard container is recreated."), true
	case "MONERO_CLEARNET_SYNC":
		return describeClearnet("Monero", new), true
	case "TARI_CLEARNET_SYNC":
		return describeClearnet("Tari", new), true
	case "MONERO_VIEW_KEY":
		return describeViewKey("Monero", old, new), true
	case "WALLET_RPC_PASSWORD":
		return change("INFO", "Payout wallet-rpc credential updated."), true
	case "PAYOUT_CONFIRM_ENABLED":
		return change("INFO", "On-chain payout confirmation → "+onOff(new)+"."), true
	case "PAYOUT_SCAN_HEIGHT":
		return change("INFO", fmt.Sprintf("Payout wallet restore height: %s → %s — only affects a first-time wallet creation.", old, new)), true
	case "TARI_VIEW_KEY":
		return describeViewKey("Tari", old, new), true
	case "TARI_WALLET_PASSWORD":
		return change("INFO", "Tari payout wallet credential updated."), true
	case "TARI_PAYOUT_CONFIRM_ENABLED":
		return change("INFO", "Tari on-chain payout confirmation → "+onOff(new)+"."), true
	case "TARI_WALLET_BIRTHDAY":
		return change("INFO", fmt.Sprintf("Tari payout wallet birthday: %s → %s (days since 2022-01-01) — only affects a first-time wallet creation.", old, new)), true
	case "TARI_SPEND_PUBLIC_KEY":
		return change("INFO", fmt.Sprintf("Tari payout confirmation spend key: %s → %s.", defaultText(old, "unset"), defaultText(new, "unset"))), true
	}
	if strings.HasSuffix(key, "_DATA_DIR") {
		return change("DEST", fmt.Sprintf("%s: %s → %s — the service will use the new (empty) directory and re-sync; old data is left in place.", key, old, new)), true
	}
	return change("INFO", fmt.Sprintf("%s: %s → %s.", key, old, new)), true
}

func describeHealthchecks(old, new string) Change {
	if new == "" {
		return change("INFO", "Healthchecks.io dead-man's switch DISABLED — ping URL cleared, so no one is alerted if this machine goes down; the dashboard container is recreated.")
	}
	if old == "" {
		return change("INFO", "Healthchecks.io dead-man's switch ENABLED — ping URL set (pings over Tor); a wrong URL stops the pings or sends them to someone else's check, so an outage here goes unnoticed; the dashboard container is recreated.")
	}
	return change("INFO", "Healthchecks.io ping URL updated — a wrong URL stops the pings or sends them to someone else's check, so an outage here goes unnoticed; the dashboard container is recreated.")
}

func describeClearnet(component, new string) Change {
	if component == "Monero" {
		if new == "true" {
			return change("CONFIRM", "⚠ Monero CLEARNET initial sync ENABLED — monerod P2P will run over CLEARNET (this host's IP becomes visible to the Monero P2P network) so the chain syncs fast. Transaction broadcast STAYS on Tor; wallets are never exposed. After sync, the host closes the exception, monerod restarts on Tor, and the warning clears only after host verification. monerod is recreated.")
		}
		return change("INFO", "Monero clearnet sync DISABLED — monerod P2P returns to Tor-only. monerod is recreated.")
	}
	if new == "true" {
		return change("CONFIRM", "⚠ Tari CLEARNET initial sync ENABLED — the Tari base node will sync over CLEARNET (TCP transport + seeds.tari.com DNS seed; this host's IP becomes visible to the Tari P2P network) so its large chain syncs fast. After sync, the host closes the exception, Tari restarts on Tor, and the warning clears only after host verification. tari is recreated.")
	}
	return change("INFO", "Tari clearnet sync DISABLED — the Tari base node returns to Tor-only transport. tari is recreated.")
}

func describeViewKey(component, old, new string) Change {
	if component == "Monero" {
		if new == "" {
			return change("INFO", "Payout confirmation view key CLEARED — the view-only wallet-rpc is removed.")
		}
		if old == "" {
			return change("DEST", "Payout confirmation view key SET — a view-only monero-wallet-rpc starts and scans the local node for confirmed payouts (it can see incoming amounts, never spend).")
		}
		return change("DEST", "Payout confirmation view key CHANGED — a new view-only wallet is opened for this address (the previous one is kept).")
	}
	if new == "" {
		return change("INFO", "Tari payout confirmation view key CLEARED — the view-only tari-wallet is removed.")
	}
	if old == "" {
		return change("DEST", "Tari payout confirmation view key SET — a view-only minotari_console_wallet starts and scans the local Tari node for confirmed payouts (it can see incoming amounts, never spend).")
	}
	return change("DEST", "Tari payout confirmation view key CHANGED — a new view-only wallet is opened for this address (the previous one is kept).")
}

func defaultText(value, fallback string) string {
	if value == "" {
		return fallback
	}
	return value
}

func onOff(value string) string {
	if value == "true" {
		return "on"
	}
	return "off"
}
