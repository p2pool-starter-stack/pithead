package overview

import (
	"bytes"
	"encoding/json"
	"math"
	"strings"
	"testing"
	"time"
)

func TestEarningsRates(t *testing.T) {
	cases := []struct {
		operation string
		args      []json.RawMessage
		want      float64
	}{
		{"xmr_per_hs_day", []json.RawMessage{raw(`600000000000`), raw(`400000000000`)}, 600000000000.0 / 1e12 / 400000000000.0 * 86400},
		{"xmr_per_hs_day", []json.RawMessage{raw(`0`), raw(`400000000000`)}, 0},
		{"xmr_per_hs_day", []json.RawMessage{raw(`9007199254740993`), raw(`3`)}, 259407338.53654063},
		{"xmr_per_hs_day", []json.RawMessage{raw(`9007199254740993`), raw(`3.5`)}, 222349147.31703484},
		{"xtm_per_hs_day", []json.RawMessage{raw(`5.5`), raw(`2000000`)}, 5.5 / 2000000 * 86400},
		{"xtm_per_hs_day", []json.RawMessage{raw(`9007199254740993`), raw(`3`)}, 2.594073385365406e20},
		{"xtm_per_hs_day", []json.RawMessage{raw(`9007199254740993`), raw(`3.5`)}, 2.2234914731703475e20},
		{"tari_seconds_to_block_per_hs", []json.RawMessage{raw(`9007199254740993`)}, 9007199254740992},
	}
	for _, test := range cases {
		got, err := Build(Request{Operation: test.operation, Args: test.args})
		if err != nil {
			t.Fatal(err)
		}
		if got.(float64) != test.want {
			t.Fatalf("%s = %.18g, want %.18g", test.operation, got, test.want)
		}
	}
	if _, err := Build(Request{Operation: "xmr_per_hs_day", Args: []json.RawMessage{raw(`"bad"`), raw(`1`)}}); err == nil {
		t.Fatal("expected invalid rate input")
	}
}

func TestPreviousLocalDayCrossesDST(t *testing.T) {
	zone, err := time.LoadLocation("America/New_York")
	if err != nil {
		t.Fatal(err)
	}
	now := time.Date(2024, 11, 4, 12, 0, 0, 0, time.UTC)
	got, err := Build(Request{Operation: "previous_local_day", Now: float64(now.Unix()), Zone: zone.String()})
	if err != nil {
		t.Fatal(err)
	}
	window := got.([]any)
	start, end := window[0].(float64), window[1].(float64)
	if end-start != 25*3600 {
		t.Fatalf("fall-back day length = %v", end-start)
	}
	if time.Unix(int64(start), 0).In(zone).Format("2006-01-02 15:04") != "2024-11-03 00:00" ||
		time.Unix(int64(end), 0).In(zone).Format("2006-01-02 15:04") != "2024-11-04 00:00" {
		t.Fatalf("unexpected local day: %v", window)
	}
}

func TestPreviousLocalDayNormalizesMissingMidnightForward(t *testing.T) {
	got, err := Build(Request{Operation: "previous_local_day", Now: 1541426400, Zone: "America/Sao_Paulo"})
	if err != nil {
		t.Fatal(err)
	}
	window := got.([]any)
	if window[0] != float64(1541300400) || window[1] != float64(1541383200) {
		t.Fatalf("missing-midnight window = %#v", window)
	}
	if window[1].(float64)-window[0].(float64) != 23*3600 {
		t.Fatalf("missing-midnight duration = %#v", window)
	}
}

func TestPreviousLocalDayCrossesSkippedDate(t *testing.T) {
	got, err := Build(Request{Operation: "previous_local_day", Now: 1325282400, Zone: "Pacific/Apia"})
	if err != nil {
		t.Fatal(err)
	}
	window := got.([]any)
	if window[0] != float64(1325152800) || window[1] != float64(1325239200) {
		t.Fatalf("skipped-date window = %#v", window)
	}
}

func TestConfirmedPayoutsSummaryBoundariesAndPrecision(t *testing.T) {
	now := float64(time.Date(2025, 1, 2, 12, 0, 0, 0, time.UTC).Unix())
	yesterday := float64(time.Date(2025, 1, 1, 0, 0, 0, 0, time.UTC).Unix())
	today := float64(time.Date(2025, 1, 2, 0, 0, 0, 0, time.UTC).Unix())
	payouts, _ := json.Marshal([]map[string]any{
		{"ts": yesterday, "amount_atomic": json.Number("9007199254740993")},
		{"ts": today, "amount_atomic": 1},
		{"ts": now + 1, "amount_atomic": 2},
		{"ts": now - 31*86400, "amount_atomic": 4},
		{"amount_atomic": 8},
	})
	got, err := Build(Request{
		Operation: "confirmed_payouts_summary", Now: now, Zone: "UTC",
		Args: []json.RawMessage{payouts, raw(`1`), raw(`"xmr"`), raw(`{"reachable":false,"lag":3}`)},
	})
	if err != nil {
		t.Fatal(err)
	}
	summary := got.(map[string]any)
	if summary["xmr_all"] != float64(9007199254741008) {
		t.Fatalf("all-time integer sum lost precision: %#v", summary["xmr_all"])
	}
	if summary["xmr_yesterday"] != float64(9007199254740992) || summary["n_30d"] != 3 {
		t.Fatalf("window boundaries differ: %#v", summary)
	}
	if summary["reachable"] != false || summary["lag"] != 3.0 && summary["lag"] != json.Number("3") {
		t.Fatalf("wallet overlay missing: %#v", summary)
	}
	partial := summary["partial"].(map[string]any)
	if partial["30d"] != false || partial["yesterday"] != false {
		t.Fatalf("unexpected partial windows: %#v", partial)
	}
	disabled, err := Build(Request{Operation: "confirmed_payouts_summary", Now: now, Zone: "UTC", Args: []json.RawMessage{raw(`null`), raw(`1000000000000`), raw(`"xmr"`), raw(`null`)}})
	if err != nil || disabled.(map[string]any)["enabled"] != false {
		t.Fatalf("disabled summary = %#v, %v", disabled, err)
	}
	disabled, err = Build(Request{Operation: "confirmed_payouts_summary", Zone: "invalid/zone", Args: []json.RawMessage{raw(`null`), raw(`0`), raw(`{}`), raw(`true`)}})
	if err != nil || len(disabled.(map[string]any)) != 1 || disabled.(map[string]any)["enabled"] != false {
		t.Fatalf("disabled summary inspected unused inputs: %#v, %v", disabled, err)
	}
}

func TestConfirmedPayoutsSummaryMatchesPythonNumericPromotion(t *testing.T) {
	mixed := raw(`[{"ts":1,"amount_atomic":1e16},{"ts":1,"amount_atomic":1},{"ts":1,"amount_atomic":-1e16}]`)
	got, err := Build(Request{
		Operation: "confirmed_payouts_summary", Now: 1, Zone: "UTC",
		Args: []json.RawMessage{mixed, raw(`1`), raw(`"xmr"`), raw(`null`)},
	})
	if err != nil {
		t.Fatal(err)
	}
	if got.(map[string]any)["xmr_all"] != float64(0) {
		t.Fatalf("mixed float sum was not sequential: %#v", got)
	}
	wide := raw(`[{"ts":1,"amount_atomic":9007199254740993}]`)
	integerDivisor, err := Build(Request{
		Operation: "confirmed_payouts_summary", Now: 1, Zone: "UTC",
		Args: []json.RawMessage{wide, raw(`3`), raw(`"xmr"`), raw(`null`)},
	})
	if err != nil {
		t.Fatal(err)
	}
	floatDivisor, err := Build(Request{
		Operation: "confirmed_payouts_summary", Now: 1, Zone: "UTC",
		Args: []json.RawMessage{wide, raw(`3.0`), raw(`"xmr"`), raw(`null`)},
	})
	if err != nil {
		t.Fatal(err)
	}
	if integerDivisor.(map[string]any)["xmr_all"] != float64(3002399751580331) ||
		floatDivisor.(map[string]any)["xmr_all"] != float64(3002399751580330.5) {
		t.Fatalf("divisor numeric kind was lost: int=%#v float=%#v", integerDivisor, floatDivisor)
	}
}

func TestBuildEarnings(t *testing.T) {
	data := raw(`{"network":{"reward":600000000000},"payout_wallet":{"monero":{"reachable":true},"tari":{"reachable":false}}}`)
	metrics := raw(`{"network_difficulty":400000000000,"p2pool_1h":2500,"tari_reward":12.5,"tari_difficulty":5000000,"tari_mining":true,"pool_difficulty":720000}`)
	got, err := Build(Request{
		Operation: "build_earnings", Now: 2_000_000_000, Zone: "UTC",
		Args: []json.RawMessage{data, metrics, raw(`[]`), raw(`null`), raw(`0.25`)},
	})
	if err != nil {
		t.Fatal(err)
	}
	earnings := got.(map[string]any)
	if earnings["available"] != true || earnings["p2pool_hr_str"] != "2.50 kH/s" || earnings["block_reward"] != "0.6000 XMR" {
		t.Fatalf("unexpected earnings: %#v", earnings)
	}
	if earnings["tari_available"] != true || earnings["tari_difficulty"] != float64(5_000_000) || earnings["xvb_day"] != json.Number("0.25") {
		t.Fatalf("unexpected Tari/XvB earnings: %#v", earnings)
	}
	if earnings["confirmed"].(map[string]any)["reachable"] != true || earnings["tari_confirmed"].(map[string]any)["enabled"] != false {
		t.Fatalf("unexpected confirmations: %#v", earnings)
	}
	_, err = Build(Request{
		Operation: "build_earnings", Zone: "invalid/zone",
		Args: []json.RawMessage{data, metrics, raw(`null`), raw(`null`), raw(`null`)},
	})
	if err != nil {
		t.Fatalf("disabled confirmations inspected zone: %v", err)
	}
}

func TestBuildEarningsPreservesRewardDivisionKinds(t *testing.T) {
	data := raw(`{"network":{"reward":9007199254740993}}`)
	metrics := raw(`{"network_difficulty":3,"p2pool_1h":1,"tari_reward":0,"tari_difficulty":0,"tari_mining":false,"pool_difficulty":1}`)
	got, err := Build(Request{
		Operation: "build_earnings",
		Args:      []json.RawMessage{data, metrics, raw(`null`), raw(`null`), raw(`null`)},
	})
	if err != nil {
		t.Fatal(err)
	}
	earnings := got.(map[string]any)
	if earnings["coeff_day"] != 259407338.53654063 || earnings["block_reward"] != "9007.1993 XMR" {
		t.Fatalf("wide reward divisions = %#v", earnings)
	}
}

func TestBuildEarningsVsActual(t *testing.T) {
	metrics := raw(`{"p2pool_30d":100,"xvb_enabled":true,"tari_mining":true,"tari_difficulty":259200000,"tari_local":null}`)
	earnings := raw(`{
		"coeff_day":0.000001,"xvb_day":0.01,
		"confirmed":{"enabled":true,"xmr_30d":0.315,"partial":{"30d":true}},
		"tari_confirmed":{"enabled":true,"n_30d":2,"xtm_30d":25,"partial":{"30d":false}}
	}`)
	wins := raw(`[{"ts":1000},{"ts":2592001},{"ts":3000000}]`)
	got, err := Build(Request{
		Operation: "build_earnings_vs_actual", Now: 2_592_000,
		Args: []json.RawMessage{metrics, earnings, wins, raw(`0.05`), raw(`[0.5,7]`)},
	})
	if err != nil {
		t.Fatal(err)
	}
	result := got.(map[string]any)
	xmr := result["xmr"].(map[string]any)
	if xmr["expected_30d"] != 0.153 || xmr["pct"] != int64(206) || xmr["xvb_realization_pct"] != int64(50) || xmr["xvb_wins_measured"] != json.Number("7") {
		t.Fatalf("unexpected XMR comparison: %#v", xmr)
	}
	tari := result["tari"].(map[string]any)
	if tari["expected_blocks_30d"] != 1.0 || tari["blocks_30d"] != json.Number("2") || tari["is_local"] != nil {
		t.Fatalf("unexpected Tari comparison: %#v", tari)
	}
	xvb := result["xvb"].(map[string]any)
	if xvb["wins_30d"] != 3 || xvb["last_win_ts"] != float64(3_000_000) || xvb["expected_wins_30d"] != 1.5 {
		t.Fatalf("unexpected XvB comparison: %#v", xvb)
	}
}

func TestEarningsComparisonWithholdsHugePercentage(t *testing.T) {
	metrics := raw(`{"p2pool_30d":1,"xvb_enabled":false,"tari_mining":false,"tari_difficulty":0,"tari_local":false}`)
	earnings := raw(`{"coeff_day":0.000000001,"xvb_day":null,"confirmed":{"enabled":true,"xmr_30d":1},"tari_confirmed":{"enabled":false}}`)
	got, err := Build(Request{Operation: "build_earnings_vs_actual", Args: []json.RawMessage{metrics, earnings, raw(`null`), raw(`null`), raw(`null`)}})
	if err != nil {
		t.Fatal(err)
	}
	xmr := got.(map[string]any)["xmr"].(map[string]any)
	if xmr["pct"] != nil {
		t.Fatalf("huge percentage was not withheld: %#v", xmr)
	}
}

func TestEarningsRoundingUsesTiesToEven(t *testing.T) {
	for value, expected := range map[float64]int64{2.5: 2, 3.5: 4, -2.5: -2} {
		got, err := pythonRound(value)
		if err != nil || got != expected {
			t.Fatalf("round(%v) = %#v, %v", value, got, err)
		}
	}
}

func TestRunPacksNonfiniteValuesOnlyWithMarker(t *testing.T) {
	request := `{"operation":"xmr_per_hs_day","args":[1,5e-324]}`
	value, err := Build(Request{Operation: "xmr_per_hs_day", Args: []json.RawMessage{raw(`1`), raw(`5e-324`)}})
	if err != nil || !math.IsInf(value.(float64), 1) {
		t.Fatalf("subnormal helper result = %#v, %v", value, err)
	}
	if err := Run(strings.NewReader(request), &bytes.Buffer{}); err == nil {
		t.Fatal("unmarked nonfinite output unexpectedly encoded")
	}
	var output bytes.Buffer
	marked := strings.TrimSuffix(request, "}") + `,"nonfinite_marker":"__pithead_nf_7f3a"}`
	if err := Run(strings.NewReader(marked), &output); err != nil {
		t.Fatal(err)
	}
	if output.String() != `{"__pithead_nf_7f3a":"inf"}`+"\n" {
		t.Fatalf("marked output = %q", output.String())
	}
	packed := packNonfinite(map[string]any{"items": []any{math.NaN(), math.Inf(-1), 2.0}}, "__marker")
	items := packed.(map[string]any)["items"].([]any)
	if items[0].(map[string]any)["__marker"] != "nan" || items[1].(map[string]any)["__marker"] != "-inf" || items[2] != 2.0 {
		t.Fatalf("recursive nonfinite packing = %#v", packed)
	}
}
