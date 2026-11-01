package domain

import "encoding/json"

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

type Input struct {
	LatestData map[string]any   `json:"latest_data"`
	History    []map[string]any `json:"history"`
	XVBStats   map[string]any   `json:"xvb_stats"`
	Tiers      []Tier           `json:"tiers"`
	Config     Config           `json:"config"`
	Now        float64          `json:"now"`
}
