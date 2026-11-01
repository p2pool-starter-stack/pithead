package domain

import (
	"bytes"
	"encoding/json"
	"errors"
)

func (config *Config) UnmarshalJSON(data []byte) error {
	var fields map[string]json.RawMessage
	if json.Unmarshal(data, &fields) != nil || fields == nil {
		return errors.New("invalid domain config")
	}
	for _, key := range []string{
		"enable_xvb", "donation_level", "max_donation_fraction", "xvb_stats_stale_after_s",
		"monero_node_host", "local_monero_host", "monero_prune", "tari_mode", "monero_local",
	} {
		if bytes.Equal(bytes.TrimSpace(fields[key]), []byte("null")) {
			return errors.New("null domain config value")
		}
	}
	type plainConfig Config
	return json.Unmarshal(data, (*plainConfig)(config))
}

func (input *Input) UnmarshalJSON(data []byte) error {
	trimmed := bytes.TrimSpace(data)
	var clock struct {
		Now json.RawMessage `json:"now"`
	}
	if len(trimmed) == 0 || trimmed[0] != '{' || json.Unmarshal(data, &clock) != nil {
		return errors.New("invalid domain input")
	}
	if bytes.Equal(bytes.TrimSpace(clock.Now), []byte("null")) {
		return errors.New("null domain clock")
	}
	type plainInput Input
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.UseNumber()
	return decoder.Decode((*plainInput)(input))
}
