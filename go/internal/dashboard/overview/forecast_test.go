package overview

import (
	"encoding/json"
	"math"
	"testing"
)

func forecastRequest(operation string, now float64, values ...any) Request {
	args := make([]json.RawMessage, len(values))
	for index, value := range values {
		encoded, err := json.Marshal(value)
		if err != nil {
			panic(err)
		}
		args[index] = encoded
	}
	return Request{Operation: operation, Args: args, Now: now}
}

func forecastSettings() map[string]any {
	return map[string]any{
		"stale_after_s": 300, "max_fraction": 0.4, "prior": []any{0.28, 0.39},
		"published_rewards": map[string]any{"donor": 0.064, "vip": 0.81, "whale": 4.67},
		"published_date":    "2026-08-10", "tier_note": "raffle status", "sidechain_note": "PPLNS warning",
		"payout_window_s": 21600, "settle_s": 43200, "min_wins": 5, "realization_window_s": 3888000,
	}
}

func forecastTiers() []any {
	return []any{
		map[string]any{"name": "vip", "threshold": 10000, "display": "Vip input label"},
		map[string]any{"name": "donor", "threshold": 1000, "display": "Donor input label"},
		map[string]any{"name": "whale", "threshold": 100000, "display": "Whale input label"},
		map[string]any{"name": "off", "threshold": 0, "display": "Off input label"},
	}
}

func forecastMetrics(overrides map[string]any) map[string]any {
	result := map[string]any{
		"xvb_enabled": true, "xvb_1h": 2100, "xvb_24h": 2300, "target_threshold": 10000,
		"current_tier": "Current input label", "target_tier": "Target input label",
		"target_sustainable": false, "pool_type": "Mini", "p2pool_30d": 100,
	}
	for key, value := range overrides {
		result[key] = value
	}
	return result
}

func TestXVBTierSelectionPreservesInsertionAtEqualThresholds(t *testing.T) {
	tiers := []any{
		map[string]any{"name": "first", "threshold": 1000, "display": "First"},
		map[string]any{"name": "second", "threshold": 1000, "display": "Second"},
	}
	got, err := Build(forecastRequest("xvb_current_tier_key", 1000, forecastMetrics(nil), tiers))
	if err != nil || got != "first" {
		t.Fatalf("current key = %#v, %v", got, err)
	}
	got, err = Build(forecastRequest("xvb_forecast_tier_key", 1000, forecastMetrics(map[string]any{"xvb_1h": 0, "xvb_24h": 0, "target_threshold": 1000}), tiers))
	if err != nil || got != "first" {
		t.Fatalf("forecast key = %#v, %v", got, err)
	}
	below, err := Build(forecastRequest("xvb_current_tier_key", 1000, forecastMetrics(map[string]any{"xvb_1h": 999, "xvb_24h": 999}), tiers))
	if err != nil || below != nil {
		t.Fatalf("below tier = %#v, %v", below, err)
	}
}

func TestXVBRewardDayUsesStrictStalenessAndEnabledGate(t *testing.T) {
	settings := forecastSettings()
	estimates := map[string]any{"estimates": map[string]any{"donor": 3.65}, "last_update": 700}
	got, err := Build(forecastRequest("xvb_current_tier_reward_day", 1000, forecastMetrics(nil), forecastTiers(), estimates, settings))
	if err != nil || got != 0.01 {
		t.Fatalf("boundary reward = %#v, %v", got, err)
	}
	estimates["last_update"] = 699
	got, err = Build(forecastRequest("xvb_current_tier_reward_day", 1000, forecastMetrics(nil), forecastTiers(), estimates, settings))
	if err != nil || got != nil {
		t.Fatalf("stale reward = %#v, %v", got, err)
	}
	estimates["last_update"] = 1000
	got, err = Build(forecastRequest("xvb_current_tier_reward_day", 1000, forecastMetrics(map[string]any{"xvb_enabled": false}), forecastTiers(), estimates, settings))
	if err != nil || got != nil {
		t.Fatalf("disabled reward = %#v, %v", got, err)
	}
}

func TestXVBExpectedWinsIncludesQualifiedTiers(t *testing.T) {
	roundState := map[string]any{
		"last_update": 1000,
		"stats": map[string]any{"span_days": 7, "types": map[string]any{
			"donor": map[string]any{"rounds": json.Number("9007199254740993"), "players_avg": 70},
			"vip":   map[string]any{"rounds": 28, "players_avg": 28},
			"whale": map[string]any{"rounds": 56, "players_avg": 8},
		}},
	}
	got, err := Build(forecastRequest("xvb_expected_wins_day", 1000, roundState, "vip", forecastTiers(), forecastSettings()))
	if err != nil {
		t.Fatal(err)
	}
	want := (9007199254740993.0/7)/70 + (28.0/7)/28
	if math.Abs(got.(float64)-want) > 0.01 {
		t.Fatalf("wins/day = %.18g, want %.18g", got, want)
	}
	roundState["last_update"] = 699
	got, err = Build(forecastRequest("xvb_expected_wins_day", 1000, roundState, "vip", forecastTiers(), forecastSettings()))
	if err != nil || got != nil {
		t.Fatalf("stale wins/day = %#v, %v", got, err)
	}
}

func TestXVBRealizationCountsOverlapOnceAndSubtractsBaseline(t *testing.T) {
	now := float64(5_000_000)
	wins := make([]any, 6)
	for index := range wins {
		wins[index] = map[string]any{"ts": now - 86400 - float64(index*3600)}
	}
	payouts := []any{map[string]any{"ts": now - 86400 + 900, "amount_atomic": json.Number("4800000000")}}
	got, err := Build(forecastRequest("xvb_realization", now, payouts, wins, 0.016, 1.0, 0.0064, forecastSettings()))
	if err != nil {
		t.Fatal(err)
	}
	measurement := got.([]any)
	want := 0.0
	if measurement[0] != want || measurement[1] != 6 {
		t.Fatalf("overlap realization = %#v", got)
	}
	payouts = make([]any, 6)
	for index, win := range wins {
		payouts[index] = map[string]any{"ts": win.(map[string]any)["ts"].(float64) + 1800, "amount_atomic": json.Number("4800000000")}
	}
	got, err = Build(forecastRequest("xvb_realization", now, payouts, wins, 0.016, 1.0, 0.0064, forecastSettings()))
	if err != nil || math.Abs(got.([]any)[0].(float64)-0.2) > 1e-12 {
		t.Fatalf("baseline realization = %#v, %v", got, err)
	}
	tooFew, err := Build(forecastRequest("xvb_realization", now, payouts[:4], wins[:4], 0.016, 1.0, 0.0064, forecastSettings()))
	if err != nil || tooFew != nil {
		t.Fatalf("minimum wins = %#v, %v", tooFew, err)
	}
}

func TestXVBTemperingUsesMeasurementThenPrior(t *testing.T) {
	got, err := Build(forecastRequest("xvb_tempered_day", 1000, 0.016, []any{0.19, 15}, forecastSettings()))
	if err != nil || math.Abs(got.(float64)-0.00304) > 1e-12 {
		t.Fatalf("measured tempering = %#v, %v", got, err)
	}
	got, err = Build(forecastRequest("xvb_tempered_day", 1000, 0.016, nil, forecastSettings()))
	if err != nil || math.Abs(got.(float64)-0.00536) > 1e-12 {
		t.Fatalf("prior tempering = %#v, %v", got, err)
	}
	got, err = Build(forecastRequest("xvb_tempered_day", 1000, nil, []any{0.19, 15}, forecastSettings()))
	if err != nil || got != nil {
		t.Fatalf("nil tempering = %#v, %v", got, err)
	}
}

func TestXVBCalcSourcesLabelsAndStableTierSort(t *testing.T) {
	tiers := []any{
		map[string]any{"name": "second", "threshold": 1000, "display": "Second source label"},
		map[string]any{"name": "first", "threshold": 1000, "display": "First source label"},
		map[string]any{"name": "vip", "threshold": 10000, "display": "Vip source label"},
	}
	rounds := map[string]any{"last_update": 1000, "stats": map[string]any{"span_days": 7, "types": map[string]any{"vip": map[string]any{"rounds": 28, "players_avg": 28}}}}
	estimates := map[string]any{"last_update": 1000, "estimates": map[string]any{"vip": 0.81}}
	got, err := Build(forecastRequest("build_xvb_calc", 1000, forecastMetrics(nil), tiers, rounds, estimates, nil, forecastSettings()))
	if err != nil {
		t.Fatal(err)
	}
	calc := got.(map[string]any)
	rows := calc["tiers"].([]map[string]any)
	if rows[0]["name"] != "Second source label" || rows[1]["name"] != "First source label" || rows[2]["name"] != "Vip source label" {
		t.Fatalf("tier labels/order = %#v", rows)
	}
	if calc["estimates_source"] != "live" || calc["mode_note"] != "PPLNS warning" || calc["note"] != "raffle status" {
		t.Fatalf("source fields = %#v", calc)
	}
	estimates["last_update"] = 699
	got, err = Build(forecastRequest("build_xvb_calc", 1000, forecastMetrics(nil), tiers, rounds, estimates, nil, forecastSettings()))
	if err != nil || got.(map[string]any)["estimates_source"] != "none" {
		t.Fatalf("enabled stale fallback = %#v, %v", got, err)
	}
	got, err = Build(forecastRequest("build_xvb_calc", 1000, forecastMetrics(map[string]any{"xvb_enabled": false, "pool_type": "Main"}), tiers, rounds, estimates, nil, forecastSettings()))
	if err != nil {
		t.Fatal(err)
	}
	calc = got.(map[string]any)
	if calc["estimates_source"] != "published" || calc["estimates_published_date"] != "2026-08-10" || calc["mode_note"] != nil {
		t.Fatalf("disabled fallback = %#v", calc)
	}
}

func TestXVBStateGatesDisabledAndUsesP2PoolDayBaseline(t *testing.T) {
	now := float64(5_000_000)
	rounds := map[string]any{"last_update": now, "stats": map[string]any{"span_days": 1, "types": map[string]any{"donor": map[string]any{"rounds": 1, "players_avg": 1}}}}
	estimates := map[string]any{"last_update": now, "estimates": map[string]any{"donor": 5.84}}
	wins, payouts := make([]any, 6), make([]any, 6)
	for index := range wins {
		stamp := now - 86400 - float64(index*3600)
		wins[index] = map[string]any{"ts": stamp}
		payouts[index] = map[string]any{"ts": stamp + 1800, "amount_atomic": 4_800_000_000}
	}
	got, err := Build(forecastRequest("xvb_state", now, forecastMetrics(map[string]any{"p2pool_30d": 100}), forecastTiers(), rounds, estimates, payouts, wins, 0.000064, forecastSettings()))
	if err != nil {
		t.Fatal(err)
	}
	state := got.(map[string]any)
	if math.Abs(state["realization"].([]any)[0].(float64)-0.2) > 1e-12 || math.Abs(state["tempered_day"].(float64)-0.0032) > 1e-12 {
		t.Fatalf("aggregate realization = %#v", state)
	}
	got, err = Build(forecastRequest("xvb_state", now, forecastMetrics(map[string]any{"xvb_enabled": false}), forecastTiers(), rounds, estimates, payouts, wins, 0.000064, forecastSettings()))
	if err != nil {
		t.Fatal(err)
	}
	state = got.(map[string]any)
	if state["xvb_day"] != nil || state["expected_wins_day"] != nil || state["realization"] != nil || state["tempered_day"] != nil {
		t.Fatalf("disabled aggregate = %#v", state)
	}
}

func TestXVBOperationsRejectMalformedInputs(t *testing.T) {
	if _, err := Build(forecastRequest("xvb_current_tier_key", 0, map[string]any{}, "not tiers")); err == nil {
		t.Fatal("expected malformed tiers error")
	}
	if _, err := Build(forecastRequest("xvb_current_tier_key", 0, map[string]any{}, []any{map[string]any{"name": "donor", "threshold": 1}})); err == nil {
		t.Fatal("expected missing display error")
	}
	if _, err := Build(forecastRequest("xvb_realization", 0, nil, nil, 1, 1, nil)); err == nil {
		t.Fatal("expected argument count error")
	}
	settings := forecastSettings()
	delete(settings, "tier_note")
	if _, err := Build(forecastRequest("xvb_tempered_day", 0, 1, nil, settings)); err == nil {
		t.Fatal("expected missing setting error")
	}
}
