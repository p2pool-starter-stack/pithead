package overview

import (
	"bytes"
	"encoding/json"
	"strings"
	"testing"
)

func raw(value string) json.RawMessage {
	return json.RawMessage(value)
}

func TestBuildPoolNetwork(t *testing.T) {
	data := `{
		"stratum":{"wallet":"WWWWWWWWWWWWWWWWWWWWWWWW","shares_found":5,"shares_failed":1,"current_effort":12.34,"block_reward_share_percent":0.125,"last_share_found_time":1,"total_stratum_shares":7,"connections":2,"total_hashes":999999999999999999999},
		"pool":{"pool":{"syncing":true,"sidechain_height":100,"total_hashes":20,"miners":3,"pplns_weight":4,"blocks_found":5,"last_block_ts":1704067110},"p2p":{"out_peers":6,"in_peers":7,"uptime":3661}},
		"network":{"reward":600000000000,"hash":"0123456789abcdefghijklmnop","timestamp":1}}
	`
	metrics := `{
		"stratum_h15":1200,"stratum_h1h":2000000,"stratum_h24h":3000000000,
		"pool_type":"Main","pool_hashrate":120000000,"pool_difficulty":250000000,
		"network_difficulty":380000000000,"network_height":42,"pplns_window":2160,
		"block_time":10,"shares_in_window":5}
	`
	result, err := Build(Request{
		Operation: "build_pool_network", Args: []json.RawMessage{raw(data), raw(metrics), raw(`{"mode":"Pruned"}`)},
		Now: 1704067200, Zone: "UTC",
	})
	if err != nil {
		t.Fatal(err)
	}
	pool := result.(map[string]any)["pool"].(map[string]any)
	if pool["hr"] != "120.00 MH/s" || pool["diff"] != "250.00 M" || pool["last_blk"] != "1m 30s ago" {
		t.Fatalf("unexpected pool: %#v", pool)
	}
	if pool["pplns_win"] != "2160 (6h 0m)" || pool["uptime"] != "1h 1m" {
		t.Fatalf("unexpected durations: %#v", pool)
	}
	stratum := result.(map[string]any)["stratum"].(map[string]any)
	if stratum["h15"] != "1.20 kH/s" || stratum["wallet_short"] != "WWWWWWWW...WWWWWWWW" {
		t.Fatalf("unexpected stratum: %#v", stratum)
	}
	if stratum["effort"] != "12.3%" || stratum["reward_pct"] != "0.1250%" || stratum["last_share"] != "00:00:01" {
		t.Fatalf("unexpected stratum formats: %#v", stratum)
	}
	if stratum["total_hashes"] != json.Number("999999999999999999999") {
		t.Fatalf("integer precision lost: %#v", stratum["total_hashes"])
	}
	network := result.(map[string]any)["network"].(map[string]any)
	if network["reward"] != "0.6000 XMR" || network["diff"] != "380.00 G" || network["hash"] != "01234567...ijklmnop" {
		t.Fatalf("unexpected network: %#v", network)
	}
	if got := result.(map[string]any)["monero"].(map[string]any)["mode"]; got != "Pruned" {
		t.Fatalf("precomputed monero not retained: %#v", got)
	}
}

func TestBuildPoolNetworkRejectsUnsupportedInputs(t *testing.T) {
	metrics := `{"stratum_h15":0,"stratum_h1h":0,"stratum_h24h":0,"pool_type":"Main","pool_hashrate":0,"pool_difficulty":0,"network_difficulty":0,"network_height":0,"pplns_window":2160,"block_time":10,"shares_in_window":0}`
	_, err := Build(Request{Operation: "build_pool_network", Args: []json.RawMessage{raw(`{"stratum":{"current_effort":"bad"}}`), raw(metrics), raw(`{}`)}})
	if err == nil {
		t.Fatal("expected invalid formatted number to fall back")
	}
	_, err = Build(Request{Operation: "build_pool_network", Args: []json.RawMessage{raw(`{}`), raw(`{}`), raw(`{}`)}})
	if err == nil {
		t.Fatal("expected missing metrics to fall back")
	}
}

func TestBuildPoolNetworkDefaults(t *testing.T) {
	metrics := `{"stratum_h15":0,"stratum_h1h":0,"stratum_h24h":0,"pool_type":"Main","pool_hashrate":0,"pool_difficulty":0,"network_difficulty":0,"network_height":0,"pplns_window":2160,"block_time":10,"shares_in_window":0}`
	result, err := Build(Request{Operation: "build_pool_network", Args: []json.RawMessage{raw(`{}`), raw(metrics), raw(`null`)}, Now: 10, Zone: "UTC"})
	if err != nil {
		t.Fatal(err)
	}
	state := result.(map[string]any)
	stratum := state["stratum"].(map[string]any)
	pool := state["pool"].(map[string]any)
	network := state["network"].(map[string]any)
	if stratum["shares"] != "0 / 0" || stratum["effort"] != "0.0%" || stratum["last_share"] != "Never" {
		t.Fatalf("unexpected stratum defaults: %#v", stratum)
	}
	if pool["last_blk"] != "Never" || pool["uptime"] != "0m 0s" || pool["syncing"] != false {
		t.Fatalf("unexpected pool defaults: %#v", pool)
	}
	if network["reward"] != "0.0000 XMR" || network["hash"] != "N/A" || network["ts"] != "Never" {
		t.Fatalf("unexpected network defaults: %#v", network)
	}
}

func TestBuildRaffleLogNewestFirstAndCapped(t *testing.T) {
	rows := make([]map[string]any, 22)
	for index := range rows {
		rows[index] = map[string]any{"ts": index + 1, "tier": "donor", "hashrate": 4.2e6, "height": index}
	}
	encoded, err := json.Marshal(rows)
	if err != nil {
		t.Fatal(err)
	}
	result, err := Build(Request{Operation: "build_raffle_log", Args: []json.RawMessage{encoded}, Zone: "UTC"})
	if err != nil {
		t.Fatal(err)
	}
	wins := result.([]any)
	if len(wins) != 20 || wins[0].(map[string]any)["height"] != json.Number("21") {
		t.Fatalf("unexpected raffle order: %#v", wins)
	}
	if wins[0].(map[string]any)["hashrate"] != "4.20 MH/s" || wins[0].(map[string]any)["time"] != "00:00:22" {
		t.Fatalf("unexpected raffle formatting: %#v", wins[0])
	}
}

func TestBuildRaffleEligibility(t *testing.T) {
	cases := []struct {
		input    string
		applies  bool
		eligible bool
		label    string
	}{
		{`{"xvb_enabled":false}`, false, false, "N/A (XvB off)"},
		{`{"xvb_enabled":true,"current_tier":"Donor","shares_in_window":1}`, true, true, "Yes"},
		{`{"xvb_enabled":true,"current_tier":"None","shares_in_window":1}`, true, false, "No"},
		{`{"xvb_enabled":true,"current_tier":"Donor","shares_in_window":0}`, true, false, "No"},
		{`{"xvb_enabled":true,"current_tier":null,"shares_in_window":2}`, true, true, "Yes"},
	}
	for _, test := range cases {
		result, err := Build(Request{Operation: "build_raffle_eligibility", Args: []json.RawMessage{raw(test.input)}})
		if err != nil {
			t.Fatal(err)
		}
		got := result.(map[string]any)
		if got["applies"] != test.applies || got["eligible"] != test.eligible || got["label"] != test.label {
			t.Fatalf("unexpected eligibility for %s: %#v", test.input, got)
		}
	}
}

func TestBuildEgressBadge(t *testing.T) {
	cases := map[string]string{
		`{"level":"ok","leaks":0,"label":"All egress via Tor"}`:       `{"text":"🛡️ Tor-only egress","title":"All egress via Tor","variant":"ok"}`,
		`{"level":"warn","leaks":0,"label":"State unverified"}`:       `{"text":"⚠️ State unverified","title":"State unverified","variant":"warn"}`,
		`{"level":"bad","leaks":2,"label":"2 clearnet egress paths"}`: `{"text":"⚠️ 2 clearnet egress paths","title":"2 clearnet egress paths","variant":"bad"}`,
	}
	for input, expected := range cases {
		result, err := Build(Request{Operation: "_egress_badge", Args: []json.RawMessage{raw(input)}})
		if err != nil {
			t.Fatal(err)
		}
		encoded, _ := json.Marshal(result)
		if string(encoded) != expected {
			t.Fatalf("got %s want %s", encoded, expected)
		}
	}
}

func TestBuildVisibleUpdate(t *testing.T) {
	update := raw(`{"available":true,"latest":"v1.9.1","url":"u","size":999999999999999999999}`)
	for running, visible := range map[string]bool{"v1.9.0": true, "v1.9.1": false, "v1.10.0": false, "dev": true} {
		result, err := Build(Request{Operation: "visible_update", Args: []json.RawMessage{update, raw(`"` + running + `"`)}})
		if err != nil {
			t.Fatal(err)
		}
		if (result != nil) != visible {
			t.Fatalf("running %s visibility = %#v", running, result)
		}
		if visible && result.(map[string]any)["size"] != json.Number("999999999999999999999") {
			t.Fatal("update integer precision lost")
		}
	}
	result, err := Build(Request{Operation: "visible_update", Args: []json.RawMessage{raw(`null`), raw(`"v1.0.0"`)}})
	if err != nil || result != nil {
		t.Fatalf("nil update = %#v, %v", result, err)
	}
	result, err = Build(Request{Operation: "visible_update", Args: []json.RawMessage{update, raw(`null`)}})
	if err != nil || result == nil {
		t.Fatalf("truthy update with nil running = %#v, %v", result, err)
	}
	result, err = Build(Request{Operation: "visible_update", Args: []json.RawMessage{raw(`null`), raw(`null`)}})
	if err != nil || result != nil {
		t.Fatalf("false update with nil running = %#v, %v", result, err)
	}
}

func TestRunUsesNumbersAndRejectsTrailingInput(t *testing.T) {
	request := `{"operation":"build_raffle_eligibility","args":[{"xvb_enabled":true,"current_tier":"Donor","shares_in_window":1}],"now":0,"zone":"UTC"}`
	var output bytes.Buffer
	if err := Run(strings.NewReader(request), &output); err != nil {
		t.Fatal(err)
	}
	if output.String() != `{"applies":true,"eligible":true,"label":"Yes"}`+"\n" {
		t.Fatalf("unexpected output: %s", output.String())
	}
	if err := Run(strings.NewReader(request+` {}`), &output); err == nil {
		t.Fatal("expected trailing input rejection")
	}
	if _, err := Build(Request{Operation: "unknown"}); err == nil {
		t.Fatal("expected unknown operation rejection")
	}
}

func TestFormattingMatchesPythonEdges(t *testing.T) {
	if got := formatDuration(json.Number("-1")); got != "23h 59m" {
		t.Fatalf("negative duration = %q", got)
	}
	if got := formatDuration(json.Number("9007199254740993")); got != "104249991374d 7h 36m" {
		t.Fatalf("large duration = %q", got)
	}
	if got := formatHashrate("nan"); got != "nan H/s" {
		t.Fatalf("nan hashrate = %q", got)
	}
	if got := shortened("αβγδεζηθικλμνξοπρστυ", 8, 16); got != "αβγδεζηθ...νξοπρστυ" {
		t.Fatalf("unicode shortening = %q", got)
	}
	if truthy(0) || truthy(0.0) || !truthy(2) || !truthy(json.Number("1e10000")) {
		t.Fatal("numeric truthiness differs from Python")
	}
}
