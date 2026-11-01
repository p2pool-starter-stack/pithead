package domain

import (
	"encoding/json"
	"math"
	"reflect"
	"testing"
)

func baseInput() Input {
	return Input{
		LatestData: map[string]any{
			"shares": []any{}, "workers": []any{}, "global_sync": false,
			"total_live_h15": json.Number("50000"),
			"monero_sync":    map[string]any{"percent": json.Number("100"), "current": json.Number("10"), "target": json.Number("10")},
			"tari_sync":      map[string]any{"percent": json.Number("40"), "current": json.Number("40"), "target": json.Number("100")},
		},
		XVBStats: map[string]any{"current_mode": "XVB (Split)"},
		Tiers: []Tier{
			{Name: "donor_mega", Threshold: json.Number("1000000")},
			{Name: "donor_whale", Threshold: json.Number("100000")},
			{Name: "donor_vip", Threshold: json.Number("10000")},
			{Name: "donor", Threshold: json.Number("1000")},
		},
		Config: Config{
			EnableXVB: true, DonationLevel: "auto", MaxDonationFraction: 0.85,
			XVBStatsStaleAfter: 900, MoneroNodeHost: "local", LocalMoneroHost: "local",
			MoneroPrune: true, TariMode: "local",
		},
		Now: 1_700_000_000,
	}
}

func TestBuildMetrics(t *testing.T) {
	input := baseInput()
	input.History = []map[string]any{
		{"timestamp": json.Number("1699999970"), "v": json.Number("1000"), "v_p2pool": json.Number("600"), "v_xvb": json.Number("400")},
		{"timestamp": json.Number("1699740800"), "v": json.Number("200"), "v_p2pool": json.Number("200"), "v_xvb": json.Number("0")},
	}
	input.XVBStats = map[string]any{
		"current_mode": "XVB (Split)", "avg_1h": json.Number("50000"), "avg_24h": json.Number("50000"),
		"fail_count": json.Number("4"), "last_update": json.Number("1699998000"),
		"registered_at": json.Number("1699999000"), "registration_state": "registered",
	}
	input.LatestData["stratum"] = map[string]any{
		"hashrate_15m": json.Number("100"), "hashrate_1h": json.Number("200"), "hashrate_24h": json.Number("300"),
	}
	input.LatestData["pool"] = map[string]any{
		"p2p": map[string]any{"type": "Nano"},
		"pool": map[string]any{
			"pplns_window": json.Number("10"), "difficulty": json.Number("18000000"),
			"hashrate": json.Number("900000"), "last_block_ts": json.Number("1699999900"),
		},
	}
	input.LatestData["network"] = map[string]any{"difficulty": json.Number("380000000000"), "height": json.Number("3210001")}
	input.LatestData["shares"] = []any{
		map[string]any{"ts": json.Number("1699999990"), "difficulty": json.Number("50")},
		map[string]any{"ts": json.Number("1699990000"), "difficulty": json.Number("999")},
	}
	input.LatestData["workers"] = []any{
		map[string]any{"status": "online"}, map[string]any{"status": "offline"},
	}
	input.LatestData["tari"] = map[string]any{"active": true, "difficulty": json.Number("420000000000"), "reward": json.Number("13000.5")}
	got, err := Build(input)
	if err != nil {
		t.Fatal(err)
	}
	checks := map[string]any{
		"total_h15": json.Number("50000"), "p2pool_1h": PythonFloat(600), "p2pool_24h": PythonFloat(600),
		"p2pool_30d": PythonFloat(400), "xvb_routed_1h": PythonFloat(400), "xvb_routed_24h": PythonFloat(400),
		"current_tier": "Vip (10.00 kH/s+)", "target_tier": "Vip (10.00 kH/s+)",
		"target_threshold": PythonFloat(10000), "target_sustainable": true, "workers_online": 1,
		"workers_total": 2, "shares_in_window": 1, "own_pplns_weight": int64(50),
		"pplns_window": json.Number("10"), "block_time": 30, "expected_share_sec": PythonFloat(30000),
		"luck_pct": PythonFloat(10000), "xvb_stale": true, "monero_mode": "Pruned",
	}
	for key, want := range checks {
		if !reflect.DeepEqual(got[key], want) {
			t.Errorf("%s = %#v, want %#v", key, got[key], want)
		}
	}
	if len(got) != 46 {
		t.Fatalf("field count = %d, want 46", len(got))
	}
	monero := got["monero"].(map[string]any)
	if monero["done"] != true || monero["remaining"] != int64(0) {
		t.Fatalf("monero sync = %#v", monero)
	}
	tari := got["tari"].(map[string]any)
	if tari["done"] != false || tari["remaining"] != int64(60) {
		t.Fatalf("tari sync = %#v", tari)
	}
}

func TestBuildDisabledAndZeroClock(t *testing.T) {
	input := baseInput()
	input.Now = 0
	input.Config.EnableXVB = false
	input.XVBStats["last_update"] = json.Number("-1000")
	got, err := Build(input)
	if err != nil {
		t.Fatal(err)
	}
	for _, key := range []string{"current_tier", "target_tier"} {
		if got[key] != "Disabled" {
			t.Errorf("%s = %#v", key, got[key])
		}
	}
	if got["mode"] != "P2POOL (XvB Disabled)" || got["xvb_stale"] != false {
		t.Fatalf("disabled state = %#v", got)
	}
}

func TestBuildRemoteAndDisabledTariLocality(t *testing.T) {
	input := baseInput()
	input.Config.MoneroNodeHost = "remote"
	input.Config.TariMode = "off"
	got, err := Build(input)
	if err != nil {
		t.Fatal(err)
	}
	if got["monero_mode"] != "Unknown" || got["monero_local"] != false {
		t.Fatalf("monero locality = %#v, %#v", got["monero_mode"], got["monero_local"])
	}
	if got["tari_local"] != nil {
		t.Fatalf("tari locality = %#v", got["tari_local"])
	}
}

func TestBuildLocalityHelperOverrides(t *testing.T) {
	input := baseInput()
	moneroLocal := false
	input.Config.MoneroLocal = &moneroLocal
	input.Config.TariMode = "off"
	input.Config.TariLocal = json.RawMessage("true")
	got, err := Build(input)
	if err != nil {
		t.Fatal(err)
	}
	if got["monero_local"] != false || got["monero_mode"] != "Pruned" {
		t.Fatalf("monero override = %#v, %#v", got["monero_local"], got["monero_mode"])
	}
	if got["tari_local"] != true {
		t.Fatalf("tari override = %#v", got["tari_local"])
	}
	input.Config.TariLocal = json.RawMessage("null")
	got, err = Build(input)
	if err != nil || got["tari_local"] != nil {
		t.Fatalf("null Tari override = %#v, %v", got["tari_local"], err)
	}
	input.Config.TariLocal = json.RawMessage(`"local"`)
	if _, err := Build(input); err == nil {
		t.Fatal("expected invalid Tari locality error")
	}
}

func TestBuildRejectsInvalidBoundaryValues(t *testing.T) {
	input := baseInput()
	input.Now = math.Inf(1)
	if _, err := Build(input); err == nil {
		t.Fatal("expected invalid clock error")
	}
	input = baseInput()
	input.LatestData["workers"] = nil
	if _, err := Build(input); err == nil {
		t.Fatal("expected invalid worker list error")
	}
}

func TestEqualTierThresholdUsesInputOrder(t *testing.T) {
	input := baseInput()
	input.Tiers = []Tier{
		{Name: "donor_first", Threshold: json.Number("1000")},
		{Name: "donor_second", Threshold: json.Number("1000")},
	}
	input.XVBStats["avg_1h"] = json.Number("1000")
	input.XVBStats["avg_24h"] = json.Number("1000")
	got, err := Build(input)
	if err != nil {
		t.Fatal(err)
	}
	if got["current_tier"] != "First (1.00 kH/s+)" {
		t.Fatalf("tier = %q", got["current_tier"])
	}
}

func TestNullTimestampsRefuseNativeProcessing(t *testing.T) {
	for _, value := range []any{nil, "", []any{}, map[string]any{}} {
		input := baseInput()
		input.History = []map[string]any{{"timestamp": value}}
		if _, err := Build(input); err == nil {
			t.Errorf("history timestamp %#v accepted", value)
		}
		input = baseInput()
		input.LatestData["shares"] = []any{map[string]any{"ts": value}}
		if _, err := Build(input); err == nil {
			t.Errorf("share timestamp %#v accepted", value)
		}
	}
}
