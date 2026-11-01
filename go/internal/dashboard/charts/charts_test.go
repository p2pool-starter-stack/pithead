package charts

import (
	"bytes"
	"encoding/json"
	"strings"
	"testing"
)

func TestBuildSeriesAndMarkers(t *testing.T) {
	input := Input{
		History: []map[string]any{
			{"timestamp": 1000.0, "t": "a", "v": 500.0, "v_p2pool": 500.0, "v_xvb": 0.0},
			{"timestamp": 1030.0, "t": "b", "v": 700.0, "v_p2pool": 0.0, "v_xvb": 700.0},
		},
		Shares:         []map[string]any{{"ts": 1015.0}},
		Range:          "all",
		Events:         []map[string]any{{"ts": 1000.0, "type": "loss", "detail": "-50%"}},
		RaffleWins:     []map[string]any{{"ts": 1000.0, "tier": "donor", "hashrate": 4.2e6}},
		Payouts:        []map[string]any{{"ts": 1000.0, "amount_atomic": 1.5e12}},
		Now:            2000,
		UpdateInterval: 30,
	}
	chart, err := Build(input)
	if err != nil {
		t.Fatal(err)
	}
	p2pool := chart["p2pool"].([]map[string]any)
	xvb := chart["xvb"].([]map[string]any)
	if p2pool[0]["x"] != int64(1_000_000) || p2pool[0]["y"] != 500.0 || xvb[1]["y"] != 700.0 {
		t.Fatalf("series = %#v %#v", p2pool, xvb)
	}
	shares := chart["shares"].([]map[string]any)
	if shares[0]["x"] != int64(1_030_000) || shares[0]["c"] != 1 {
		t.Fatalf("tie did not choose right sample: %#v", shares)
	}
	if chart["events"].([]map[string]any)[0]["label"] != "-50%" {
		t.Fatalf("events = %#v", chart["events"])
	}
	if chart["raffle"].([]map[string]any)[0]["label"] != "XvB raffle win — donor round at 4.20 MH/s" {
		t.Fatalf("raffle = %#v", chart["raffle"])
	}
	if !strings.HasPrefix(chart["payouts"].([]map[string]any)[0]["label"].(string), "1.500000 XMR — ") {
		t.Fatalf("payouts = %#v", chart["payouts"])
	}
}

func TestBuildFiltersDownsamplesAndBreaks(t *testing.T) {
	history := make([]map[string]any, 0, 1000)
	for i := 0; i < 500; i++ {
		history = append(history, map[string]any{"timestamp": float64(1000 + i*30), "t": "x", "v": float64(i), "v_p2pool": float64(i), "v_xvb": 0.0, "v_p2pool_1m": 900.0})
	}
	for i := 0; i < 500; i++ {
		history = append(history, map[string]any{"timestamp": float64(100000 + i*30), "t": "x", "v": float64(i), "v_p2pool": float64(i), "v_xvb": 0.0, "v_p2pool_1m": 900.0})
	}
	chart, err := Build(Input{History: history, Range: "all", AvgWindow: "1m", Now: 200000, UpdateInterval: 30})
	if err != nil {
		t.Fatal(err)
	}
	points := chart["p2pool"].([]map[string]any)
	if len(points) > 701 {
		t.Fatalf("not downsampled: %d", len(points))
	}
	breaks := 0
	for _, point := range points {
		if point["y"] == nil {
			breaks++
		} else if point["y"] != 900.0 {
			t.Fatalf("selected window lost: %#v", point)
		}
	}
	if breaks != 1 || chart["tension"] != 0.35 {
		t.Fatalf("breaks/tension = %d %#v", breaks, chart["tension"])
	}
}

func TestFilteringWindowAndRange(t *testing.T) {
	history := []map[string]any{
		{"timestamp": 1000.0, "t": "a", "v": 1.0, "v_p2pool": 1.0},
		{"timestamp": 2000.0, "t": "b", "v": 2.0, "v_p2pool": 2.0},
		{"timestamp": 3000.0, "t": "c", "v": 3.0, "v_p2pool": 3.0},
	}
	window := [2]float64{1500, 2500}
	chart, err := Build(Input{History: history, Range: "1h", Window: &window, Now: 10000})
	if err != nil {
		t.Fatal(err)
	}
	if got := chart["p2pool"].([]map[string]any); len(got) != 1 || got[0]["x"] != int64(2_000_000) {
		t.Fatalf("window = %#v", got)
	}
	chart, err = Build(Input{History: history, Range: "1h", Now: 4000})
	if err != nil || len(chart["p2pool"].([]map[string]any)) != 3 {
		t.Fatalf("range = %#v %v", chart, err)
	}
}

func TestDirectWindowAllowsZeroNegativeAndReversedBounds(t *testing.T) {
	history := []map[string]any{{"timestamp": 30.0, "t": "a", "v_p2pool_1m": 900.0}}
	for _, window := range [][2]float64{{0, 86400}, {-60, 60}} {
		chart, err := Build(Input{History: history, Range: "24h", Window: &window, AvgWindow: "1m", Now: 1000})
		if err != nil {
			t.Fatal(err)
		}
		if got := chart["p2pool"].([]map[string]any); len(got) != 1 || got[0]["y"] != 900.0 {
			t.Fatalf("window %#v = %#v", window, got)
		}
	}
	reversed := [2]float64{60, -60}
	chart, err := Build(Input{History: history, Range: "all", Window: &reversed, Now: 1000})
	if err != nil || len(chart["p2pool"].([]map[string]any)) != 0 || chart["tension"] != 0.0 {
		t.Fatalf("reversed = %#v %v", chart, err)
	}
}

func TestLegacyFallbackAndPayoutCap(t *testing.T) {
	row := map[string]any{"timestamp": 1000.0, "t": "a", "v": 800.0, "v_p2pool": 0.0, "v_xvb": 0.0}
	chart, err := Build(Input{History: []map[string]any{row}, Range: "all", Now: 2000})
	if err != nil || chart["p2pool"].([]map[string]any)[0]["y"] != 800.0 {
		t.Fatalf("default fallback = %#v %v", chart, err)
	}
	chart, err = Build(Input{History: []map[string]any{row}, Range: "all", AvgWindow: "1h", Now: 2000})
	if err != nil || chart["p2pool"].([]map[string]any)[0]["y"] != 0.0 {
		t.Fatalf("nondefault fallback = %#v %v", chart, err)
	}
	payouts := make([]map[string]any, 205)
	for i := range payouts {
		payouts[i] = map[string]any{"ts": float64(1000 - i), "amount_atomic": 1e12}
	}
	chart, err = Build(Input{History: []map[string]any{row}, Payouts: payouts, Range: "all", Now: 2000})
	if err != nil || len(chart["payouts"].([]map[string]any)) != 200 {
		t.Fatalf("payout cap = %#v %v", chart["payouts"], err)
	}
}

func TestParseAndCanonicalWindow(t *testing.T) {
	if got := ParseWindow("1000", json.Number("2000")); got == nil || *got != [2]float64{1000, 2000} {
		t.Fatalf("window = %#v", got)
	}
	for _, pair := range [][2]any{{nil, "2"}, {"bad", "2"}, {"2", "1"}, {"NaN", "2"}} {
		if got := ParseWindow(pair[0], pair[1]); got != nil {
			t.Fatalf("accepted %#v", pair)
		}
	}
	if CanonicalWindow("1h") != "1h" || CanonicalWindow("bad") != "10m" {
		t.Fatal("canonical window changed")
	}
}

func TestRunAndMalformedInputs(t *testing.T) {
	request := `{"history":[],"shares":[],"range":"all","events":[],"raffle_wins":[],"payouts":[],"now":1000,"update_interval":30}`
	var output bytes.Buffer
	if err := Run(strings.NewReader(request), &output); err != nil {
		t.Fatal(err)
	}
	var chart map[string]any
	if err := json.Unmarshal(output.Bytes(), &chart); err != nil || chart["tension"] != 0.0 {
		t.Fatalf("output = %s %v", output.String(), err)
	}
	bad := []string{
		`{`, request + `{}`,
		`{"history":[{"timestamp":"bad"}],"range":"all","now":1,"update_interval":30}`,
		`{"history":[{"timestamp":"1","v":2}],"range":"all","now":1,"update_interval":30}`,
		`{"history":[],"range":"all","window":[0,"bad"],"now":1,"update_interval":30}`,
	}
	for _, value := range bad {
		if err := Run(strings.NewReader(value), &bytes.Buffer{}); err == nil {
			t.Fatalf("accepted %q", value)
		}
	}
}
