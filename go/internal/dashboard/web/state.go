package web

import (
	"encoding/json"

	"github.com/p2pool-starter-stack/pithead/go/internal/dashboard/charts"
	"github.com/p2pool-starter-stack/pithead/go/internal/dashboard/series"
)

func buildState(raw json.RawMessage) (map[string]json.RawMessage, error) {
	var input struct {
		State        map[string]json.RawMessage `json:"state"`
		Chart        charts.Input               `json:"chart"`
		Series       map[string]series.Request  `json:"series"`
		Presentation map[string]json.RawMessage `json:"presentation"`
		Overview     map[string]json.RawMessage `json:"overview"`
	}
	if json.Unmarshal(raw, &input) != nil || input.State == nil {
		return nil, ErrInputsUnavailable
	}
	chart, err := charts.Build(input.Chart)
	if err != nil {
		return nil, err
	}
	input.State["chart"], err = json.Marshal(chart)
	if err != nil {
		return nil, err
	}
	for field, request := range input.Series {
		if !seriesField(field, request.Operation) {
			return nil, ErrInputsUnavailable
		}
		value, err := series.Build(request)
		if err != nil {
			return nil, err
		}
		input.State[field], err = json.Marshal(value)
		if err != nil {
			return nil, err
		}
	}
	for field, request := range input.Presentation {
		value, err := buildPresentation(field, request)
		if err != nil {
			return nil, err
		}
		input.State[field], err = json.Marshal(value)
		if err != nil {
			return nil, err
		}
	}
	return completeOverview(input.State, input.Overview)
}

func seriesField(field, operation string) bool {
	switch field {
	case "share_stats", "blocks", "payouts", "disk_growth", "xvb_history", "hashrate", "cadence":
		return operation == "build_"+field
	case "reject_pct_24h":
		return operation == "_window_reject_pct"
	}
	return false
}
