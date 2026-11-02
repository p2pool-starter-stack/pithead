package runtime

import (
	"encoding/json"
	"errors"

	"github.com/p2pool-starter-stack/pithead/go/internal/dashboard/overview"
)

func forecastSection(metrics map[string]any, earnings any, raw json.RawMessage) (any, error) {
	var snapshot struct {
		Storage struct {
			RoundStats json.RawMessage            `json:"xvb_round_stats"`
			Estimates  json.RawMessage            `json:"xvb_reward_estimates"`
			Payouts    map[string]json.RawMessage `json:"payouts"`
			Wins       json.RawMessage            `json:"raffle_wins"`
		} `json:"storage"`
		Settings struct {
			Tiers         json.RawMessage `json:"forecast_tiers"`
			Forecast      json.RawMessage `json:"forecast"`
			PayoutEnabled *bool           `json:"payout_confirm_enabled"`
			Now           *float64        `json:"now"`
		} `json:"settings"`
	}
	if json.Unmarshal(raw, &snapshot) != nil || snapshot.Settings.Now == nil || snapshot.Settings.PayoutEnabled == nil {
		return nil, errors.New("invalid frozen XvB forecast snapshot")
	}
	base, ok := earnings.(map[string]any)
	if !ok || base["coeff_day"] == nil {
		return nil, errors.New("missing native forecast earnings")
	}
	payouts := json.RawMessage("null")
	if *snapshot.Settings.PayoutEnabled {
		payouts = snapshot.Storage.Payouts["monero"]
	}
	for _, value := range []json.RawMessage{
		snapshot.Settings.Tiers, snapshot.Storage.RoundStats, snapshot.Storage.Estimates,
		payouts, snapshot.Storage.Wins, snapshot.Settings.Forecast,
	} {
		if value == nil {
			return nil, errors.New("missing frozen XvB forecast input")
		}
	}
	request := overview.Request{Operation: "xvb_state", Now: *snapshot.Settings.Now}
	for _, value := range []any{
		metrics, snapshot.Settings.Tiers, snapshot.Storage.RoundStats, snapshot.Storage.Estimates,
		payouts, snapshot.Storage.Wins, base["coeff_day"], snapshot.Settings.Forecast,
	} {
		if value == nil {
			return nil, errors.New("missing frozen XvB forecast input")
		}
		encoded, err := json.Marshal(value)
		if err != nil {
			return nil, err
		}
		request.Args = append(request.Args, encoded)
	}
	return overview.Build(request)
}
