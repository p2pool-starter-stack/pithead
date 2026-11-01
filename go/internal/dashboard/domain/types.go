package domain

import "encoding/json"

func (input Input) averages() (float64, float64, float64, float64, float64, error) {
	if input.Averages != nil {
		values := input.Averages
		return values.P2Pool1H, values.P2Pool24H, values.P2Pool30D, values.XVBRouted1H, values.XVBRouted24H, nil
	}
	p2pool1H, err := average(input.History, 3600, input.Now, "v_p2pool", true)
	if err != nil {
		return 0, 0, 0, 0, 0, err
	}
	p2pool24H, err := average(input.History, 86400, input.Now, "v_p2pool", true)
	if err != nil {
		return 0, 0, 0, 0, 0, err
	}
	p2pool30D, err := average(input.History, 30*86400, input.Now, "v_p2pool", true)
	if err != nil {
		return 0, 0, 0, 0, 0, err
	}
	xvbRouted1H, err := average(input.History, 3600, input.Now, "v_xvb", false)
	if err != nil {
		return 0, 0, 0, 0, 0, err
	}
	xvbRouted24H, err := average(input.History, 86400, input.Now, "v_xvb", false)
	return p2pool1H, p2pool24H, p2pool30D, xvbRouted1H, xvbRouted24H, err
}

type Tier struct {
	Name      string `json:"name"`
	Threshold any    `json:"threshold"`
}

type Config struct {
	EnableXVB           bool            `json:"enable_xvb"`
	DonationLevel       string          `json:"donation_level"`
	MaxDonationFraction float64         `json:"max_donation_fraction"`
	XVBStatsStaleAfter  float64         `json:"xvb_stats_stale_after_s"`
	MoneroNodeHost      string          `json:"monero_node_host"`
	LocalMoneroHost     string          `json:"local_monero_host"`
	MoneroPrune         bool            `json:"monero_prune"`
	TariMode            string          `json:"tari_mode"`
	MoneroLocal         *bool           `json:"monero_local,omitempty"`
	TariLocal           json.RawMessage `json:"tari_local,omitempty"`
}

type Averages struct {
	P2Pool1H     float64 `json:"p2pool_1h"`
	P2Pool24H    float64 `json:"p2pool_24h"`
	P2Pool30D    float64 `json:"p2pool_30d"`
	XVBRouted1H  float64 `json:"xvb_routed_1h"`
	XVBRouted24H float64 `json:"xvb_routed_24h"`
}

type Input struct {
	LatestData map[string]any   `json:"latest_data"`
	History    []map[string]any `json:"history"`
	XVBStats   map[string]any   `json:"xvb_stats"`
	Tiers      []Tier           `json:"tiers"`
	Config     Config           `json:"config"`
	Now        float64          `json:"now"`
	Averages   *Averages        `json:"averages,omitempty"`
}
