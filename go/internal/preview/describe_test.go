package preview

import (
	"strings"
	"testing"
)

func TestDescribeRepresentativeBranches(t *testing.T) {
	tests := []struct {
		key, old, new, tari, flag, text string
	}{
		{"TARI_GRPC_ADDRESS", "old", "new", "off", "INFO", "inactive while merge-mining is off"},
		{"MONERO_PRUNE", "1", "0", "", "DEST", "RE-SYNC from scratch"},
		{"COMPOSE_PROFILES", "", "local_node", "", "DEST", "LOCAL Monero node"},
		{"PROXY_STRATUM_PASSWORD", "secret-old", "secret-new", "", "DEST", "access-password CHANGED"},
		{"P2POOL_FLAGS", "--mini", "--nano", "", "INFO", "sidechain changing"},
		{"MONERO_NODE_PASSWORD", "secret-old", "secret-new", "", "CONFIRM", "RPC login changed"},
		{"TELEGRAM_EVENT_WALLET_CHANGED", "true", "false", "", "DEST", "Wallet-change alarm OFF"},
		{"TELEGRAM_EVENT_", "false", "true", "", "INFO", "Telegram alert toggle (TELEGRAM_EVENT_): false → true."},
		{"DASHBOARD_EXPOSE_PUBLIC_IP", "false", "true", "", "CONFIRM", "Dashboard PUBLISHED"},
		{"DASHBOARD_AUTH_PW_FP", "old", "new", "", "INFO", ""},
		{"TARI_SPEND_PUBLIC_KEY", "", "new", "", "INFO", "unset → new"},
		{"SOME_NEW_KEY", "old", "new", "", "INFO", "SOME_NEW_KEY: old → new."},
	}
	for _, test := range tests {
		t.Run(test.key, func(t *testing.T) {
			got, ok := Describe(test.key, test.old, test.new, test.tari)
			if !ok || got.Flag != test.flag || !strings.Contains(got.Message, test.text) {
				t.Fatalf("got %#v, %v", got, ok)
			}
			if strings.Contains(got.Message, "secret-old") || strings.Contains(got.Message, "secret-new") {
				t.Fatalf("secret rendered in %q", got.Message)
			}
		})
	}
}

func TestDescribeCallbackBranchesAreUnsupported(t *testing.T) {
	tests := [][3]string{
		{"TARI_MODE", "off", "local"},
		{"PROXY_STRATUM_PASSWORD", "", "new"},
		{"TOR_AUTO_HEAL", "true", "false"},
		{"XVB_TOR_ENABLED", "true", "false"},
		{"P2POOL_CLEARNET", "false", "true"},
	}
	for _, test := range tests {
		if got, ok := Describe(test[0], test[1], test[2], ""); ok {
			t.Fatalf("%s unexpectedly supported: %#v", test[0], got)
		}
	}
}

func TestDescribeRejectsLocaleSensitivePoolFlags(t *testing.T) {
	if got, ok := Describe("P2POOL_FLAGS", "--mini", "--mini\u00a0--no-dns", ""); ok {
		t.Fatalf("unexpectedly supported: %#v", got)
	}
}

func TestDescribeTariOffPrecedesCallbackFallback(t *testing.T) {
	got, ok := Describe("TARI_CLEARNET_SYNC", "false", "true", "off")
	if !ok || got.Flag != "INFO" || !strings.Contains(got.Message, "inactive") {
		t.Fatalf("got %#v, %v", got, ok)
	}
}
