package overview

import "errors"

func buildRaffleLog(request Request) (any, error) {
	values, err := arguments(request.Args, 1)
	if err != nil {
		return nil, err
	}
	wins, err := array(values[0])
	if err != nil {
		return nil, err
	}
	zone, err := location(request.Zone)
	if err != nil {
		return nil, err
	}
	limit := len(wins)
	if limit > 20 {
		limit = 20
	}
	result := make([]any, 0, limit)
	for index := len(wins) - 1; index >= len(wins)-limit; index-- {
		win, err := object(wins[index])
		if err != nil {
			return nil, err
		}
		ts, err := required(win, "ts")
		if err != nil {
			return nil, err
		}
		tier, err := required(win, "tier")
		if err != nil {
			return nil, err
		}
		hashrate, err := required(win, "hashrate")
		if err != nil {
			return nil, err
		}
		height, err := required(win, "height")
		if err != nil {
			return nil, err
		}
		result = append(result, map[string]any{
			"time": formatTimeAbs(ts, zone), "tier": tier, "hashrate": formatHashrate(hashrate), "height": height,
		})
	}
	return result, nil
}

func buildRaffleEligibility(request Request) (any, error) {
	values, err := arguments(request.Args, 1)
	if err != nil {
		return nil, err
	}
	metrics, err := object(values[0])
	if err != nil {
		return nil, err
	}
	enabled, ok := metrics["xvb_enabled"].(bool)
	if !ok {
		return nil, errors.New("invalid xvb_enabled")
	}
	if !enabled {
		return map[string]any{"applies": false, "eligible": false, "label": "N/A (XvB off)"}, nil
	}
	tier, ok := metrics["current_tier"]
	if !ok {
		return nil, errors.New("missing current_tier")
	}
	shares, ok := metrics["shares_in_window"]
	if !ok {
		return nil, errors.New("missing shares_in_window")
	}
	hasShares, err := positive(shares)
	if err != nil {
		return nil, err
	}
	disabled := false
	if name, ok := tier.(string); ok {
		disabled = name == "None" || name == "Disabled"
	}
	eligible := !disabled && hasShares
	label := "No"
	if eligible {
		label = "Yes"
	}
	return map[string]any{"applies": true, "eligible": eligible, "label": label}, nil
}
