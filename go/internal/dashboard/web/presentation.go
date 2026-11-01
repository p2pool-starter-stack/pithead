package web

import (
	"encoding/json"

	"github.com/p2pool-starter-stack/pithead/go/internal/dashboard/fleet"
	"github.com/p2pool-starter-stack/pithead/go/internal/dashboard/resources"
)

func buildPresentation(field string, raw json.RawMessage) (any, error) {
	var request struct {
		Helper    string `json:"helper"`
		Operation string `json:"operation"`
	}
	if json.Unmarshal(raw, &request) != nil || request.Operation != "build_"+field {
		return nil, ErrInputsUnavailable
	}
	switch field {
	case "workers", "energy":
		if request.Helper != "fleet" {
			return nil, ErrInputsUnavailable
		}
		var input fleet.Request
		if err := json.Unmarshal(raw, &input); err != nil {
			return nil, err
		}
		return fleet.Build(input)
	case "host_resources":
		if request.Helper != "resources" {
			return nil, ErrInputsUnavailable
		}
		var input resources.Request
		if err := json.Unmarshal(raw, &input); err != nil {
			return nil, err
		}
		return resources.Build(input)
	}
	return nil, ErrInputsUnavailable
}
