package web

import (
	"encoding/json"

	"github.com/p2pool-starter-stack/pithead/go/internal/dashboard/badges"
	"github.com/p2pool-starter-stack/pithead/go/internal/dashboard/overview"
)

func completeOverview(state map[string]json.RawMessage, requests map[string]json.RawMessage) (map[string]json.RawMessage, error) {
	operations := map[string]string{
		"pool_network": "build_pool_network", "badges": "build_badges",
		"egress_badge": "_egress_badge", "raffle_eligible": "build_raffle_eligibility",
		"raffle_wins": "build_raffle_log", "update": "visible_update",
	}
	values := map[string]any{}
	for field, raw := range requests {
		var request overview.Request
		if json.Unmarshal(raw, &request) != nil || operations[field] == "" || operations[field] != request.Operation {
			return nil, ErrInputsUnavailable
		}
		var value any
		var err error
		if field == "badges" {
			var input badges.Request
			if json.Unmarshal(raw, &input) != nil {
				return nil, ErrInputsUnavailable
			}
			value, err = badges.Build(input)
		} else {
			value, err = overview.Build(request)
		}
		if err != nil {
			return nil, err
		}
		values[field] = value
	}
	if pool, present := values["pool_network"]; present {
		raw, err := json.Marshal(pool)
		if err != nil {
			return nil, err
		}
		var fields map[string]json.RawMessage
		if json.Unmarshal(raw, &fields) != nil || len(fields) != 5 {
			return nil, ErrInputsUnavailable
		}
		for _, field := range []string{"stratum", "pool", "network", "monero", "shares_window"} {
			if fields[field] == nil {
				return nil, ErrInputsUnavailable
			}
			state[field] = fields[field]
		}
		delete(values, "pool_network")
	}
	baseBadges, haveBadges := values["badges"]
	egressBadge, haveEgress := values["egress_badge"]
	if haveBadges != haveEgress {
		return nil, ErrInputsUnavailable
	}
	if haveBadges {
		raw, err := json.Marshal(baseBadges)
		if err != nil {
			return nil, err
		}
		var list []any
		if json.Unmarshal(raw, &list) != nil {
			return nil, ErrInputsUnavailable
		}
		values["badges"] = append(list, egressBadge)
		delete(values, "egress_badge")
	}
	for field, value := range values {
		raw, err := json.Marshal(value)
		if err != nil {
			return nil, err
		}
		state[field] = raw
	}
	return state, nil
}
