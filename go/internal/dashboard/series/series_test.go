package series

import (
	"bytes"
	"encoding/json"
	"reflect"
	"strings"
	"testing"
)

func request(operation string, now float64, args ...any) Request {
	raw := make([]json.RawMessage, len(args))
	for i, arg := range args {
		raw[i], _ = json.Marshal(arg)
	}
	return Request{Operation: operation, Args: raw, Now: now, Zone: "UTC"}
}

func normalized(t *testing.T, value any) any {
	t.Helper()
	data, err := json.Marshal(value)
	if err != nil {
		t.Fatal(err)
	}
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.UseNumber()
	var result any
	if err := decoder.Decode(&result); err != nil {
		t.Fatal(err)
	}
	return result
}

func requireJSON(t *testing.T, got, want any) {
	t.Helper()
	if !reflect.DeepEqual(normalized(t, got), normalized(t, want)) {
		t.Fatalf("got %#v, want %#v", got, want)
	}
}

func TestLargeDurationsAndIntegerTimestamps(t *testing.T) {
	if got := formatDuration(1e20); got != "1157407407407407d 9h 46m" {
		t.Fatalf("large duration = %q", got)
	}
	rows := []map[string]any{{"ts": json.Number("9007199254740993")}}
	result, err := Build(request("build_blocks", 0, rows, "all"))
	if err != nil {
		t.Fatal(err)
	}
	requireJSON(t, result, []any{map[string]any{"x": json.Number("9007199254740993000"), "height": 0, "difficulty": 0}})
}

func TestMalformedTrailingArgumentReturnsError(t *testing.T) {
	for _, raw := range []string{`[] {`, `[] true`, `[] !`} {
		var rows []map[string]any
		if err := decode(json.RawMessage(raw), &rows); err == nil {
			t.Errorf("malformed argument %q accepted", raw)
		}
	}
}

func TestShareOperations(t *testing.T) {
	rows := []map[string]any{
		{"ts": -4000, "accepted": 1, "rejected": 2, "invalid": 3, "expired": 4},
		{"ts": -20, "accepted": 5, "rejected": 1},
		{"ts": -10, "accepted": 7, "rejected": 0},
		{"ts": -1, "accepted": 9, "rejected": 1},
	}
	got, err := Build(request("build_share_stats", 0, rows, "1h"))
	if err != nil {
		t.Fatal(err)
	}
	requireJSON(t, got, []any{
		map[string]any{"x": -20000, "a": 5, "r": 1, "i": 0, "e": 0},
		map[string]any{"x": -10000, "a": 7, "r": 0, "i": 0, "e": 0},
		map[string]any{"x": -1000, "a": 9, "r": 1, "i": 0, "e": 0},
	})

	filtered, err := Build(request("_filter_share_stats", 0, rows, "all", []float64{-20, -10}))
	if err != nil {
		t.Fatal(err)
	}
	requireJSON(t, filtered, rows[1:3])

	downsampled, err := Build(request("_downsample_share_stats", 0, rows, 2))
	if err != nil {
		t.Fatal(err)
	}
	requireJSON(t, downsampled, []any{
		map[string]any{"ts": -20, "accepted": 6, "rejected": 3, "invalid": 3, "expired": 4},
		map[string]any{"ts": -1, "accepted": 16, "rejected": 1, "invalid": 0, "expired": 0},
	})

	pct, err := Build(request("_window_reject_pct", 0, rows, 30))
	if err != nil {
		t.Fatal(err)
	}
	if pct != "8.70%" {
		t.Fatalf("reject percent = %v", pct)
	}
}

func TestGaugeAndEventOperations(t *testing.T) {
	rows := []map[string]any{
		{"ts": 1, "value": 1.005},
		{"ts": 2, "value": 2.005},
		{"ts": 3, "value": 4.0},
		{"ts": 4, "value": 6.0},
	}
	downsampled, err := Build(request("_downsample_gauge_rows", 10, rows, []string{"value"}, 2))
	if err != nil {
		t.Fatal(err)
	}
	requireJSON(t, downsampled, []any{
		map[string]any{"ts": 2, "value": 1.5},
		map[string]any{"ts": 4, "value": json.Number("5.0")},
	})

	gauge, err := Build(request("_gauge_series", 10, rows, "all", nil, []string{"value"}))
	if err != nil {
		t.Fatal(err)
	}
	requireJSON(t, gauge, []any{
		map[string]any{"x": 1000, "value": 1.005},
		map[string]any{"x": 2000, "value": 2.005},
		map[string]any{"x": 3000, "value": 4.0},
		map[string]any{"x": 4000, "value": 6.0},
	})

	blocks, err := Build(request("build_blocks", 10, []map[string]any{{"ts": 2, "height": 42, "difficulty": nil}}, "all"))
	if err != nil {
		t.Fatal(err)
	}
	requireJSON(t, blocks, []any{map[string]any{"x": 2000, "height": 42, "difficulty": nil}})

	payouts, err := Build(request("build_payouts", 10, map[string]any{
		"monero": []map[string]any{{"ts": 3, "amount_atomic": 12}},
		"tari":   []map[string]any{},
	}, "all"))
	if err != nil {
		t.Fatal(err)
	}
	requireJSON(t, payouts, map[string]any{
		"monero": []any{map[string]any{"x": 3000, "amount": 12}},
		"tari":   []any{},
	})
}

func TestNamedGaugeOperations(t *testing.T) {
	diskRows := []map[string]any{{"ts": 2, "monero_db_bytes": 10, "disk_used_gb": 2.5, "disk_total_gb": nil}}
	disk, err := Build(request("build_disk_growth", 10, diskRows, "all"))
	if err != nil {
		t.Fatal(err)
	}
	requireJSON(t, disk, []any{map[string]any{
		"x": 2000, "monero_db_bytes": 10, "disk_used_gb": 2.5, "disk_total_gb": nil,
	}})
	xvbRows := []map[string]any{{"ts": 3, "avg_1h": 1.0, "avg_24h": 2.0, "fail_count": 3, "donation_fraction": 0.5}}
	xvb, err := Build(request("build_xvb_history", 10, xvbRows, "all"))
	if err != nil {
		t.Fatal(err)
	}
	requireJSON(t, xvb, []any{map[string]any{
		"x": 3000, "avg_1h": 1.0, "avg_24h": 2.0, "fail_count": 3, "donation_fraction": 0.5,
	}})
}

func TestDisplayOperations(t *testing.T) {
	for mode, want := range map[string][]string{
		"P2POOL":      {"ok", "ok", "muted"},
		"XVB":         {"purple", "muted", "purple"},
		"XVB (Split)": {"accent", "ok", "purple"},
	} {
		got, err := Build(request("_mode_palette", 0, mode))
		if err != nil {
			t.Fatal(err)
		}
		requireJSON(t, got, want)
	}

	metrics := map[string]any{
		"mode": "XVB", "total_h15": 10500, "p2pool_1h": 8000, "p2pool_24h": 9000,
		"xvb_1h": 2100, "xvb_24h": 2200, "xvb_routed_1h": 2000, "xvb_routed_24h": 1900,
		"current_tier": "Vip", "target_tier": "Whale", "xvb_fail_count": 3,
		"xvb_last_update": 3661, "xvb_stale": true, "low_hr_warning": true,
	}
	hashrate, err := Build(request("build_hashrate", 0, metrics, "purple", "muted", "purple"))
	if err != nil {
		t.Fatal(err)
	}
	value := hashrate.(map[string]any)
	if value["total"] != "10.50 kH/s" || value["xvb_updated"] != "01:01:01" || value["low_hr"] == nil {
		t.Fatalf("hashrate = %#v", value)
	}

	cadence, err := Build(request("build_cadence", 1000, map[string]any{
		"last_block_ts": 910, "expected_share_sec": 3600, "luck_pct": 123.4, "own_pplns_weight": 1234567,
	}))
	if err != nil {
		t.Fatal(err)
	}
	requireJSON(t, cadence, map[string]any{
		"last_block": "00:15:10", "since_block": "1m 30s", "tts": "1h 0m",
		"luck": "123%", "weight": "1,234,567", "available": true,
	})

	unavailable, err := Build(request("build_cadence", 0, map[string]any{
		"last_block_ts": 0.0, "expected_share_sec": 0.0, "luck_pct": 0.0, "own_pplns_weight": 0.0,
	}))
	if err != nil {
		t.Fatal(err)
	}
	if unavailable.(map[string]any)["last_block"] != "Never" {
		t.Fatalf("zero last block = %#v", unavailable)
	}
}

func TestRunStrictJSONAndFailures(t *testing.T) {
	input := `{"operation":"_mode_palette","args":["XVB"],"now":0,"zone":"UTC"}`
	var output bytes.Buffer
	if err := Run(strings.NewReader(input), &output); err != nil {
		t.Fatal(err)
	}
	if output.String() != "[\"purple\",\"muted\",\"purple\"]\n" {
		t.Fatalf("output = %q", output.String())
	}
	if err := Run(strings.NewReader(input+` {}`), &output); err == nil {
		t.Fatal("accepted trailing input")
	}
	if _, err := Build(request("unknown", 0)); err == nil {
		t.Fatal("accepted unsupported operation")
	}
	bad := request("build_blocks", 0, []map[string]any{{"height": 1}}, "all")
	if _, err := Build(bad); err == nil {
		t.Fatal("accepted missing timestamp")
	}
	badZone := request("build_cadence", 0, map[string]any{
		"last_block_ts": 0, "expected_share_sec": 0, "luck_pct": 0, "own_pplns_weight": 0,
	})
	badZone.Zone = "not/a-zone"
	if _, err := Build(badZone); err == nil {
		t.Fatal("accepted invalid zone")
	}
}
