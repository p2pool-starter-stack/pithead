package badges

import (
	"bytes"
	"encoding/json"
	"reflect"
	"strings"
	"testing"
)

func testRequest(t *testing.T, operation string, values ...any) Request {
	t.Helper()
	args := make([]json.RawMessage, len(values))
	for index, value := range values {
		encoded, err := json.Marshal(value)
		if err != nil {
			t.Fatal(err)
		}
		args[index] = encoded
	}
	return Request{Operation: operation, Args: args, Now: 1000 + 71*3600, Zone: "UTC"}
}

func testMetrics() map[string]any {
	return map[string]any{
		"global_syncing": false, "mode": "P2POOL", "pool_type": "Mini",
		"low_hr_warning": false, "xvb_enabled": true, "shares_in_window": 5,
		"xvb_registration_state": "", "xvb_registered_at": 0,
		"monero":      map[string]any{"down": false},
		"tari":        map[string]any{"down": false, "percent": 0},
		"monero_mode": "Unknown",
	}
}

func testSettings() map[string]any {
	return map[string]any{
		"disk_warn_percent": 85, "disk_critical_percent": 95,
		"low_ram_available_gb": 1.5, "low_ram_floor_gb": 14,
		"monero_local": true, "tari_local": true,
	}
}

func badgeTexts(value any) []string {
	rows := value.([]any)
	result := make([]string, len(rows))
	for index, row := range rows {
		result[index] = row.(map[string]any)["text"].(string)
	}
	return result
}

func TestBuildBadgesPreservesPriorityAndFormatting(t *testing.T) {
	metrics := testMetrics()
	metrics["low_hr_warning"] = true
	metrics["shares_in_window"] = 0
	metrics["xvb_registration_state"] = "failing"
	metrics["xvb_registered_at"] = 1
	metrics["tari"] = map[string]any{"down": true, "percent": 42}
	metrics["monero_mode"] = "Pruned"
	data := map[string]any{
		"monero_sync":      map[string]any{"health": map[string]any{"level": "red", "reasons": []any{"no peers"}, "advice": "restart"}},
		"workers_rejected": true, "miner_held": true, "fail_closed_held": true,
		"tari_syncing_passive": true,
		"system": map[string]any{
			"disk":      map[string]any{"percent": 95.5},
			"hugepages": []any{"Disabled", "status-bad", "0/0"},
			"memory":    map[string]any{"total_gb": 8, "available_gb": 0.8},
			"avx2":      false,
		},
	}
	wallet := map[string]any{"old8": "4Aaaaaaa", "new8": "4Bbbbbbb", "ts": 1000}
	value, err := Build(testRequest(t, "build_badges", data, metrics, "ok", false, wallet, testSettings()))
	if err != nil {
		t.Fatal(err)
	}
	want := []string{
		"⚠ Payout wallet changed", "⚠ DB write failing", "P2POOL", "P2Pool Mini",
		"⚠ Hashrate low for tier", "⚠ No PPLNS share — XvB wins skipped",
		"⚠ XvB registration failing", "Monero chain unhealthy", "Tari DOWN",
		"Workers rejected", "Miner held (sync)", "Miner held (fail-closed)",
		"Tari syncing 42%", "XMR Pruned", "⚠ Disk 96% full", "⚠ HugePages off",
		"⚠ Low RAM (8 GB)", "⚠ Memory pressure (0.8 GB free)", "⚠ No AVX2",
	}
	if got := badgeTexts(value); !reflect.DeepEqual(got, want) {
		t.Fatalf("unexpected badge order:\n got %#v\nwant %#v", got, want)
	}
	rows := value.([]any)
	if got := rows[0].(map[string]any)["title"]; got != "4Aaaaaaa… → 4Bbbbbbb… at 00:16:40" {
		t.Fatalf("unexpected wallet title: %v", got)
	}
	if got := rows[7].(map[string]any)["title"]; got != "no peers; restart" {
		t.Fatalf("unexpected health title: %v", got)
	}
}

func TestSyncStillShowsHealthBadges(t *testing.T) {
	metrics := testMetrics()
	metrics["global_syncing"] = true
	metrics["monero"] = map[string]any{"down": true}
	value, err := Build(testRequest(t, "build_badges", map[string]any{"workers_rejected": true}, metrics, "ok", true, nil, testSettings()))
	if err != nil {
		t.Fatal(err)
	}
	want := []string{"Syncing...", "monerod DOWN", "Workers rejected"}
	if got := badgeTexts(value); !reflect.DeepEqual(got, want) {
		t.Fatalf("unexpected syncing badges: %#v", got)
	}
}

func TestRecentWalletChangeWindowAndSnapshot(t *testing.T) {
	event := map[string]any{
		"payout_wallet_changed_ts": "1000", "payout_wallet_prev8": "4Aaaaaaa",
		"payout_wallet": "4Bbbbbbbbbbbbbbbbb",
	}
	value, err := Build(testRequest(t, "recent_wallet_change", event))
	if err != nil {
		t.Fatal(err)
	}
	want := map[string]any{"old8": "4Aaaaaaa", "new8": "4Bbbbbbb", "ts": float64(1000)}
	if !reflect.DeepEqual(value, want) {
		t.Fatalf("unexpected wallet change: %#v", value)
	}
	request := testRequest(t, "recent_wallet_change", event)
	request.Now = 1000 + 72*3600
	value, err = Build(request)
	if err != nil || value != nil {
		t.Fatalf("expired change was returned: %#v %v", value, err)
	}
	event["payout_wallet_changed_ts"] = "junk"
	value, err = Build(testRequest(t, "recent_wallet_change", event))
	if err != nil || value != nil {
		t.Fatalf("unreadable change was returned: %#v %v", value, err)
	}
}

func TestValidationAndRunFailurePaths(t *testing.T) {
	settings := testSettings()
	settings["tari_local"] = nil
	if _, err := Build(testRequest(t, "build_badges", map[string]any{}, testMetrics(), "ok", true, nil, settings)); err != nil {
		t.Fatalf("off Tari locality must be accepted: %v", err)
	}
	delete(settings, "disk_warn_percent")
	if _, err := Build(testRequest(t, "build_badges", map[string]any{}, testMetrics(), "ok", true, nil, settings)); err == nil {
		t.Fatal("missing setting was accepted")
	}
	input := `{"operation":"recent_wallet_change","args":[{}],"now":1,"zone":"UTC"} {}`
	if err := Run(strings.NewReader(input), &bytes.Buffer{}); err == nil {
		t.Fatal("multiple inputs were accepted")
	}
	if _, err := Build(testRequest(t, "unknown")); err == nil {
		t.Fatal("unknown operation was accepted")
	}
	request := testRequest(t, "build_badges", map[string]any{}, testMetrics(), "ok", true, map[string]any{"old8": "a", "new8": "b", "ts": 1}, testSettings())
	request.Zone = "not/a-zone"
	if _, err := Build(request); err == nil {
		t.Fatal("invalid time zone was accepted")
	}
}

func TestPythonGeneralFormatting(t *testing.T) {
	if got := general(1234567); got != "1.23457e+06" {
		t.Fatalf("unexpected general format: %q", got)
	}
}
