package runtime

import (
	"encoding/json"
	"math"
	"testing"
)

func forecastRuntimeSnapshot(t *testing.T, enabled, payoutEnabled bool) map[string]any {
	t.Helper()
	now := float64(5_000_000)
	wins := make([]any, 6)
	payouts := make([]any, 6)
	for index := range wins {
		stamp := now - 86400 - float64(index*3600)
		wins[index] = map[string]any{"ts": stamp}
		payouts[index] = map[string]any{"ts": stamp + 1800, "amount_atomic": 4_800_000_000}
	}
	return map[string]any{
		"storage": map[string]any{
			"xvb_round_stats": map[string]any{
				"last_update": now - 300,
				"stats": map[string]any{"span_days": 1, "types": map[string]any{
					"first":  map[string]any{"rounds": 1, "players_avg": 1},
					"second": map[string]any{"rounds": 0, "players_avg": 1},
				}},
			},
			"xvb_reward_estimates": map[string]any{
				"last_update": now - 300,
				"estimates":   map[string]any{"first": 5.84, "second": 58.4},
			},
			"payouts":     map[string]any{"monero": payouts},
			"raffle_wins": wins,
		},
		"settings": map[string]any{
			"forecast_tiers": []any{
				map[string]any{"name": "first", "threshold": 1000, "display": "First frozen label"},
				map[string]any{"name": "second", "threshold": 1000, "display": "Second frozen label"},
			},
			"forecast": map[string]any{
				"stale_after_s": 300, "max_fraction": 0.4, "prior": []any{0.28, 0.39},
				"published_rewards": map[string]any{"first": 0.064, "second": 0.81},
				"published_date":    "2026-08-10", "tier_note": "frozen tier note",
				"sidechain_note": "frozen sidechain note", "payout_window_s": 21600,
				"settle_s": 43200, "min_wins": 5, "realization_window_s": 3888000,
			},
			"payout_confirm_enabled": payoutEnabled,
			"now":                    now,
		},
	}
}

func forecastRuntimeMetrics(enabled bool) map[string]any {
	return map[string]any{
		"xvb_enabled": enabled, "xvb_1h": 2000, "xvb_24h": 2000,
		"target_threshold": 1000, "current_tier": "current frozen label",
		"target_tier": "target frozen label", "target_sustainable": true,
		"pool_type": "Mini", "p2pool_30d": 100,
	}
}

func forecastRuntimeRaw(t *testing.T, snapshot map[string]any) json.RawMessage {
	t.Helper()
	encoded, err := json.Marshal(snapshot)
	if err != nil {
		t.Fatal(err)
	}
	return encoded
}

func TestForecastSectionUsesFrozenEnabledInputs(t *testing.T) {
	snapshot := forecastRuntimeSnapshot(t, true, true)
	got, err := forecastSection(
		forecastRuntimeMetrics(true), map[string]any{"coeff_day": 0.000064},
		forecastRuntimeRaw(t, snapshot),
	)
	if err != nil {
		t.Fatal(err)
	}
	state := got.(map[string]any)
	if state["current_key"] != "first" || state["forecast_key"] != "first" {
		t.Fatalf("stable tied tier selection = %#v", state)
	}
	if math.Abs(state["xvb_day"].(float64)-0.016) > 1e-12 || math.Abs(state["expected_wins_day"].(float64)-1) > 1e-12 {
		t.Fatalf("frozen forecast values = %#v", state)
	}
	if math.Abs(state["realization"].([]any)[0].(float64)-0.2) > 1e-12 || math.Abs(state["tempered_day"].(float64)-0.0032) > 1e-12 {
		t.Fatalf("frozen realization = %#v", state)
	}
	calc := state["xvb_calc"].(map[string]any)
	rows := calc["tiers"].([]map[string]any)
	if rows[0]["name"] != "First frozen label" || rows[1]["name"] != "Second frozen label" || calc["note"] != "frozen tier note" || calc["mode_note"] != "frozen sidechain note" {
		t.Fatalf("frozen calculator transport = %#v", calc)
	}
}

func TestForecastSectionDisabledDoesNotRequireMoneroPayouts(t *testing.T) {
	snapshot := forecastRuntimeSnapshot(t, false, false)
	delete(snapshot["storage"].(map[string]any)["payouts"].(map[string]any), "monero")
	got, err := forecastSection(
		forecastRuntimeMetrics(false), map[string]any{"coeff_day": 0.000064},
		forecastRuntimeRaw(t, snapshot),
	)
	if err != nil {
		t.Fatal(err)
	}
	state := got.(map[string]any)
	if state["xvb_day"] != nil || state["expected_wins_day"] != nil || state["realization"] != nil || state["tempered_day"] != nil {
		t.Fatalf("disabled forecast = %#v", state)
	}
	calc := state["xvb_calc"].(map[string]any)
	if calc["estimates_source"] != "live" || calc["enabled"] != false {
		t.Fatalf("disabled calculator = %#v", calc)
	}
}

func TestForecastSectionRejectsMissingFrozenInputs(t *testing.T) {
	cases := []struct {
		name string
		drop func(map[string]any)
	}{
		{"round stats", func(s map[string]any) { delete(s["storage"].(map[string]any), "xvb_round_stats") }},
		{"estimates", func(s map[string]any) { delete(s["storage"].(map[string]any), "xvb_reward_estimates") }},
		{"wins", func(s map[string]any) { delete(s["storage"].(map[string]any), "raffle_wins") }},
		{"tiers", func(s map[string]any) { delete(s["settings"].(map[string]any), "forecast_tiers") }},
		{"forecast", func(s map[string]any) { delete(s["settings"].(map[string]any), "forecast") }},
		{"clock", func(s map[string]any) { delete(s["settings"].(map[string]any), "now") }},
		{"payout flag", func(s map[string]any) { delete(s["settings"].(map[string]any), "payout_confirm_enabled") }},
		{"enabled payout", func(s map[string]any) { delete(s["storage"].(map[string]any)["payouts"].(map[string]any), "monero") }},
	}
	for _, test := range cases {
		t.Run(test.name, func(t *testing.T) {
			snapshot := forecastRuntimeSnapshot(t, true, true)
			test.drop(snapshot)
			if _, err := forecastSection(forecastRuntimeMetrics(true), map[string]any{"coeff_day": 0.000064}, forecastRuntimeRaw(t, snapshot)); err == nil {
				t.Fatal("expected missing frozen input error")
			}
		})
	}
	if _, err := forecastSection(forecastRuntimeMetrics(true), map[string]any{"coeff_day": 0.000064}, json.RawMessage(`{"settings":`)); err == nil {
		t.Fatal("expected invalid snapshot error")
	}
}

func TestForecastSectionRejectsMissingNativeEarnings(t *testing.T) {
	raw := forecastRuntimeRaw(t, forecastRuntimeSnapshot(t, true, true))
	for _, earnings := range []any{nil, map[string]any{}, map[string]any{"coeff_day": nil}, "reference earnings"} {
		if _, err := forecastSection(forecastRuntimeMetrics(true), earnings, raw); err == nil {
			t.Fatalf("expected native earnings error for %#v", earnings)
		}
	}
}
