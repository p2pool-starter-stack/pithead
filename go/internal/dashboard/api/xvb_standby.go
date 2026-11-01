package api

import (
	"bytes"
	"encoding/json"
	"errors"
)

func BuildXVBStandby(raw json.RawMessage, donationLevel string) (map[string]any, error) {
	values := map[string]json.RawMessage{}
	trimmed := bytes.TrimSpace(raw)
	if len(trimmed) == 0 || bytes.Equal(trimmed, []byte("null")) {
		return nil, errors.New("invalid XVB standby state")
	}
	if err := json.Unmarshal(raw, &values); err != nil {
		return nil, err
	}
	result := map[string]any{
		"commanded_fraction": 0.0,
		"avg_1h":             0.0,
		"avg_24h":            0.0,
		"mode":               "",
		"donation_level":     donationLevel,
		"ts":                 0.0,
	}
	for output, input := range map[string]string{
		"commanded_fraction": "commanded_fraction",
		"avg_1h":             "avg_1h",
		"avg_24h":            "avg_24h",
		"mode":               "current_mode",
		"ts":                 "last_update",
	} {
		value, ok := values[input]
		if !ok {
			continue
		}
		var decoded any
		decoder := json.NewDecoder(bytes.NewReader(value))
		decoder.UseNumber()
		if err := decoder.Decode(&decoded); err != nil {
			return nil, err
		}
		if !jsonNumberComplete(decoder) {
			return nil, errors.New("invalid XVB standby value")
		}
		result[output] = decoded
	}
	return result, nil
}
