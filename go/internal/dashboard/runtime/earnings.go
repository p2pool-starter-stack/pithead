package runtime

import (
	"encoding/json"
	"errors"

	"github.com/p2pool-starter-stack/pithead/go/internal/dashboard/overview"
)

func earningsSection(data, metrics map[string]any, raw json.RawMessage) (any, error) {
	var input struct {
		Storage struct {
			Payouts map[string]json.RawMessage `json:"payouts"`
		} `json:"storage"`
		Settings struct {
			PayoutEnabled     *bool    `json:"payout_confirm_enabled"`
			TariPayoutEnabled *bool    `json:"tari_payout_confirm_enabled"`
			Now               *float64 `json:"now"`
			Zone              *string  `json:"zone"`
		} `json:"settings"`
	}
	if json.Unmarshal(raw, &input) != nil || input.Settings.PayoutEnabled == nil || input.Settings.TariPayoutEnabled == nil || input.Settings.Now == nil || input.Settings.Zone == nil {
		return nil, errors.New("invalid native earnings inputs")
	}
	payouts := []json.RawMessage{json.RawMessage("null"), json.RawMessage("null")}
	for index, chain := range []string{"monero", "tari"} {
		enabled := []*bool{input.Settings.PayoutEnabled, input.Settings.TariPayoutEnabled}[index]
		if *enabled {
			payouts[index] = input.Storage.Payouts[chain]
			if payouts[index] == nil {
				return nil, errors.New("missing native earnings payouts")
			}
		}
	}
	request := overview.Request{Operation: "build_earnings", Now: *input.Settings.Now, Zone: *input.Settings.Zone}
	for _, value := range []any{data, metrics} {
		encoded, err := json.Marshal(value)
		if err != nil {
			return nil, err
		}
		request.Args = append(request.Args, encoded)
	}
	request.Args = append(request.Args, payouts[0], payouts[1], json.RawMessage("null"))
	return overview.Build(request)
}
