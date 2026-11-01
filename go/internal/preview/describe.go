package preview

import (
	"fmt"
	"regexp"
	"strings"
)

type Change struct {
	Flag    string
	Message string
}

var poolSelector = regexp.MustCompile(`(^|[[:space:]])--(mini|nano)([[:space:]]|$)`)

func Describe(key, old, new, tariMode string) (Change, bool) {
	if tariMode == "off" && (key == "TARI_GRPC_ADDRESS" || key == "TARI_CLEARNET_SYNC") {
		return change("INFO", fmt.Sprintf("Tari setting %s is inactive while merge-mining is off; Tari will not run.", key)), true
	}
	if result, ok := describeNotification(key, old, new); ok {
		return result, true
	}
	if (key == "XVB_TOR_ENABLED" && new == "false") || (key == "P2POOL_CLEARNET" && new == "true") {
		return Change{}, false
	}
	if result, ok := describeExposure(key, new); ok {
		return result, true
	}
	return describeStack(key, old, new)
}

func describeStack(key, old, new string) (Change, bool) {
	switch key {
	case "MONERO_PRUNE":
		if new == "true" || new == "1" {
			return change("CONFIRM", fmt.Sprintf("Monero pruning ENABLED (%s → %s) — prunes existing blocks to reclaim disk; monerod is recreated. Restoring the full chain later needs a wipe + re-sync.", old, new)), true
		}
		return change("DEST", fmt.Sprintf("Monero pruning DISABLED (%s → %s) — pruned data can't be restored, so the full chain must RE-SYNC from scratch.", old, new)), true
	case "COMPOSE_PROFILES":
		oldLocal, newLocal := token(old, "local_node"), token(new, "local_node")
		if !oldLocal && newLocal {
			return change("DEST", "Switching to a LOCAL Monero node — monerod will start and SYNC the blockchain (large download / disk use)."), true
		}
		if oldLocal && !newLocal {
			return change("DEST", "Switching to a REMOTE Monero node — the local monerod container will be STOPPED and removed (its on-disk data is kept)."), true
		}
		return change("INFO", fmt.Sprintf("Compose profiles: %s → %s.", old, new)), true
	case "TARI_MODE":
		if new == "local" {
			return Change{}, false
		}
		if new == "off" {
			return change("CONFIRM", fmt.Sprintf("Tari merge-mining OFF (%s → off) — p2pool stops merge-mining and any local tari container is stopped and removed. Its chain data on disk is KEPT, so turning Tari back on resumes instead of re-syncing.", old)), true
		}
		return change("CONFIRM", fmt.Sprintf("Tari merge-mining ON, external node (%s → remote) — p2pool merge-mines against the node at tari.remote; no tari container runs on this host. Monero mining continues; merge-mining starts when Tari has synced (on an already-mining machine).", old)), true
	case "MONERO_WALLET_ADDRESS":
		return change("DEST", "Monero payout address is changing — future mining rewards go to the new address."), true
	case "TARI_WALLET_ADDRESS":
		return change("DEST", "Tari payout address is changing — future merge-mining rewards go to the new address."), true
	case "MONERO_RPC_BIND":
		return bindChange(new == "0.0.0.0", "Monero RPC will be EXPOSED on your LAN (%s → %s) — make sure this is intended.", "Monero RPC bind address: %s → %s.", old, new), true
	case "MONERO_ZMQ_BIND":
		return bindChange(new == "0.0.0.0", "Monero ZMQ will be EXPOSED on your LAN (%s → %s) — it has no auth, trusted networks only.", "Monero ZMQ bind address: %s → %s.", old, new), true
	case "TARI_GRPC_BIND":
		return bindChange(new == "0.0.0.0", "Tari gRPC will be EXPOSED on your LAN (%s → %s) — it is plaintext and unauthenticated, trusted networks only.", "Tari gRPC bind address: %s → %s.", old, new), true
	case "STRATUM_BIND":
		return bindChange(new == "0.0.0.0", "The stratum port will be published on ALL interfaces (%s → %s) — keep it firewalled to your LAN.", "Stratum bind address: %s → %s (workers must reach this address).", old, new), true
	case "STRATUM_PORT":
		if old == "" {
			return change("INFO", fmt.Sprintf("Stratum port recorded (:%s) — no rig change needed.", new)), true
		}
		return change("CONFIRM", fmt.Sprintf("Stratum port: %s → %s — EVERY RIG must repoint at the new port (RigForge: pool.port) or it can't connect; the xmrig-proxy container is recreated.", old, new)), true
	case "PROXY_STRATUM_TLS":
		if new == "true" {
			return change("INFO", "Stratum TLS ENABLED — the proxy serves TLS and cleartext on the same port; rigs opt in by pinning the cert fingerprint (shown after apply). xmrig-proxy is recreated."), true
		}
		return change("INFO", "Stratum TLS DISABLED — rigs with pools[].tls:true will fail to connect until switched back to cleartext. xmrig-proxy is recreated."), true
	case "PROXY_TLS_DIR":
		return change("INFO", fmt.Sprintf("Stratum TLS keypair directory: %s → %s — the cert (and its pinned fingerprint) does NOT move with it; rigs re-pin if a new cert is generated.", old, new)), true
	case "PROXY_STRATUM_PASSWORD":
		if new == "" {
			return change("INFO", "Stratum access-password DISABLED — any rig that can reach :3333 may mine again."), true
		}
		if old == "" {
			return Change{}, false
		}
		return change("DEST", "Stratum access-password CHANGED — update every rig's 'pass' to match or they're rejected; the xmrig-proxy container is recreated."), true
	case "PROXY_DONATE_LEVEL":
		if old == "" {
			old = "0"
		}
		return change("INFO", fmt.Sprintf("xmrig-proxy dev-fee donation level: %s%% → %s%% — the xmrig-proxy container is recreated (brief restart).", old, new)), true
	case "DASHBOARD_DATA_DIR":
		if old == "" {
			return change("CONFIRM", fmt.Sprintf("%s: unset → %s — the dashboard keeps its database here.", key, new)), true
		}
		return change("CONFIRM", fmt.Sprintf("%s: %s → %s — any dashboard database at %s (history and the payout-wallet alarm baseline) is copied there and verified, and the old copy stays in place; only the automatic join of the default under the shared data root moves it instead. A non-empty target refuses the move.", key, old, new, old)), true
	case "MONERO_DATA_DIR", "TARI_DATA_DIR", "P2POOL_DATA_DIR", "TOR_DATA_DIR":
		return change("CONFIRM", fmt.Sprintf("%s: %s → %s — the service will use the new (empty) directory and RE-SYNC from scratch; old data is left in place.", key, old, new)), true
	case "P2POOL_FLAGS", "P2POOL_PORT":
		if key == "P2POOL_FLAGS" && (!ascii(old) || !ascii(new)) {
			return Change{}, false
		}
		return describePool(key, old, new), true
	case "MONERO_NODE_HOST", "MONERO_RPC_PORT", "MONERO_ZMQ_PORT", "TARI_GRPC_ADDRESS":
		return describeEndpoint(key, old, new), true
	case "MONERO_NODE_USERNAME", "MONERO_NODE_PASSWORD":
		return change("CONFIRM", fmt.Sprintf("Monero node RPC login changed (%s) — the stack authenticates to its configured node with this credential from now on. If the new value is wrong, the node connection fails closed rather than falling back to the old one; put the old value back to reverse it.", key)), true
	case "XVB_ENABLED", "XVB_POOL_URL", "XVB_DONOR_ID", "XVB_DONATION_LEVEL":
		return change("INFO", fmt.Sprintf("XMRvsBeast setting (%s): %s → %s.", key, old, new)), true
	}
	return describeStackMore(key, old, new)
}

func change(flag, message string) Change { return Change{Flag: flag, Message: message} }

func token(value, wanted string) bool {
	for _, item := range strings.Split(value, ",") {
		if item == wanted {
			return true
		}
	}
	return false
}

func ascii(value string) bool {
	for i := 0; i < len(value); i++ {
		if value[i] >= 0x80 {
			return false
		}
	}
	return true
}

func bindChange(exposed bool, danger, normal, old, new string) Change {
	if exposed {
		return change("DEST", fmt.Sprintf(danger, old, new))
	}
	return change("INFO", fmt.Sprintf(normal, old, new))
}

func describePool(key, old, new string) Change {
	oldPool, newPool := "main", "main"
	if match := poolSelector.FindStringSubmatch(old); match != nil {
		oldPool = match[2]
	}
	if match := poolSelector.FindStringSubmatch(new); match != nil {
		newPool = match[2]
	}
	if key == "P2POOL_PORT" || oldPool != newPool {
		return change("INFO", fmt.Sprintf("P2Pool sidechain changing (%s: '%s' → '%s') — p2pool re-syncs the new sidechain and your PPLNS window resets.", key, old, new))
	}
	return change("INFO", fmt.Sprintf("P2Pool peer routing changed — proxy routing, DNS lookups and IP visibility to peers follow the new settings; the %s sidechain stays selected.", newPool))
}

func describeEndpoint(key, old, new string) Change {
	prefix := strings.SplitN(key, "_", 2)[0]
	if old == "" {
		old = "unset"
	}
	message := fmt.Sprintf("%s node endpoint (%s): %s → %s — the stack points its RPC client THERE and trusts the chain data, block templates and share heights that address returns. Confirm-gated, not free-commit, because it moves TRUST rather than disk; the host probes the new endpoint before accepting it, and putting the old address back reverses it.", prefix, key, old, new)
	if key == "TARI_GRPC_ADDRESS" {
		message += " Monero mining continues; merge-mining starts when Tari has synced (on an already-mining machine)."
	}
	return change("CONFIRM", message)
}
