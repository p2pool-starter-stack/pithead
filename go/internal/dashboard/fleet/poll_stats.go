package fleet

import (
	"encoding/json"
	"errors"
)

var pollShareKeys = []string{"accepted", "rejected", "invalid", "expired"}

func pollParseProxySummary(request Request) (any, error) {
	values, err := detailArguments(request, 1)
	if err != nil {
		return nil, err
	}
	return parseProxySummary(values[0])
}

func parseProxySummary(value any) (map[string]any, error) {
	payload, ok := value.(map[string]any)
	if !ok {
		return map[string]any{}, nil
	}
	resultsValue := member(payload, "results", map[string]any{})
	if !truthy(resultsValue) {
		resultsValue = map[string]any{}
	}
	results, err := object(resultsValue)
	if err != nil {
		return nil, err
	}
	bestValue := member(results, "best", []any{})
	if !truthy(bestValue) {
		bestValue = []any{}
	}
	best, err := array(bestValue)
	if err != nil {
		return nil, err
	}
	bestResult := any(json.Number("0"))
	if len(best) > 0 {
		bestResult = best[0]
	}
	return map[string]any{
		"accepted": pollZero(member(results, "accepted", json.Number("0"))),
		"rejected": pollZero(member(results, "rejected", json.Number("0"))),
		"invalid":  pollZero(member(results, "invalid", json.Number("0"))),
		"expired":  pollZero(member(results, "expired", json.Number("0"))),
		"best":     bestResult,
	}, nil
}

func pollMergeProxySummary(request Request) (any, error) {
	values, err := detailArguments(request, 2)
	if err != nil {
		return nil, err
	}
	parsed, err := parseProxySummary(values[1])
	if err != nil {
		return nil, err
	}
	if len(parsed) != 0 {
		return map[string]any{"adopt": true, "summary": parsed}, nil
	}
	return map[string]any{"adopt": false, "summary": nil}, nil
}

func pollMergeDirectStats(request Request) (any, error) {
	values, err := detailArguments(request, 4)
	if err != nil {
		return nil, err
	}
	workers, err := array(values[0])
	if err != nil {
		return nil, err
	}
	results, err := array(values[1])
	if err != nil {
		return nil, err
	}
	rigforge, err := array(values[3])
	if err != nil {
		return nil, err
	}
	limit := min(len(workers), len(results))
	output := make([]any, 0, limit)
	for index := 0; index < limit; index++ {
		worker, err := object(workers[index])
		if err != nil {
			return nil, err
		}
		patch := map[string]any{}
		extra := map[string]any(nil)
		if truthy(results[index]) {
			extra, err = object(results[index])
			if err != nil {
				return nil, err
			}
		}
		var apiOK any
		if extra != nil {
			apiOK = member(extra, "api_ok", nil)
		}
		if apiOK != nil {
			patch["api_ok"] = apiOK
			patch["adopted"] = truthy(member(extra, "adopted", nil))
		}
		if extra != nil && index < len(rigforge) && rigforge[index] != nil {
			patch["rigforge"] = rigforge[index]
		}
		if truthy(apiOK) {
			existingUptime, err := required(worker, "uptime")
			if err != nil {
				return nil, err
			}
			if uptime, ok := extra["uptime"]; ok {
				patch["uptime"] = uptime
			} else {
				patch["uptime"] = existingUptime
			}
			scale := any(json.Number("1"))
			if member(extra, "kind", nil) == "proxy" {
				scale = json.Number("1000")
			}
			hashrate, err := object(member(extra, "hashrate", map[string]any{}))
			if err != nil {
				return nil, err
			}
			total, ok := hashrate["total"].([]any)
			if ok && len(total) >= 3 {
				for source, key := range []string{"h10", "h60", "h15"} {
					patch[key], err = pollArithmetic(pollZero(total[source]), scale, '*')
					if err != nil {
						return nil, err
					}
				}
			}
		}
		patch["active_pool"] = values[2]
		output = append(output, patch)
	}
	return output, nil
}

func pollAggregateHashrate(request Request) (any, error) {
	values, err := detailArguments(request, 1)
	if err != nil {
		return nil, err
	}
	workers, err := array(values[0])
	if err != nil {
		return nil, err
	}
	headline, h10 := any(json.Number("0")), any(json.Number("0"))
	for _, value := range workers {
		worker, err := object(value)
		if err != nil {
			return nil, err
		}
		if member(worker, "status", nil) != "online" {
			continue
		}
		effective := pollZero(member(worker, "h15", json.Number("0")))
		if !truthy(effective) {
			effective = pollZero(member(worker, "h60", json.Number("0")))
		}
		if !truthy(effective) {
			effective = pollZero(member(worker, "h10", json.Number("0")))
		}
		headline, err = pollAdd(headline, effective)
		if err != nil {
			return nil, err
		}
		h10, err = pollAdd(h10, member(worker, "h10", json.Number("0")))
		if err != nil {
			return nil, err
		}
	}
	return []any{headline, h10}, nil
}

func pollAggregateWindowHashrates(request Request) (any, error) {
	values, err := detailArguments(request, 1)
	if err != nil {
		return nil, err
	}
	workers, err := array(values[0])
	if err != nil {
		return nil, err
	}
	keys := map[string]string{"1m": "h10", "1h": "h1h", "12h": "h12h", "24h": "h24h"}
	totals := map[string]any{"1m": json.Number("0"), "1h": json.Number("0"), "12h": json.Number("0"), "24h": json.Number("0")}
	for _, value := range workers {
		worker, err := object(value)
		if err != nil {
			return nil, err
		}
		if member(worker, "status", nil) != "online" {
			continue
		}
		for window, key := range keys {
			totals[window], err = pollAdd(totals[window], pollZero(member(worker, key, json.Number("0"))))
			if err != nil {
				return nil, err
			}
		}
	}
	return totals, nil
}

func pollSummaryDeltas(request Request) (any, error) {
	values, err := detailArguments(request, 2)
	if err != nil {
		return nil, err
	}
	current, err := object(values[1])
	if err != nil {
		return nil, err
	}
	if values[0] == nil {
		return []any{nil, current}, nil
	}
	last, err := object(values[0])
	if err != nil {
		return nil, err
	}
	deltas := make(map[string]any, len(pollShareKeys))
	advanced := false
	for _, key := range pollShareKeys {
		before, ok := last[key]
		if !ok {
			return nil, errors.New("missing " + key)
		}
		after, ok := current[key]
		if !ok {
			return nil, errors.New("missing " + key)
		}
		beforeNumber, _, err := pollNumber(before)
		if err != nil {
			return nil, err
		}
		afterNumber, _, err := pollNumber(after)
		if err != nil {
			return nil, err
		}
		if afterNumber.Cmp(beforeNumber) < 0 {
			return []any{nil, current}, nil
		}
		deltas[key], err = pollArithmetic(after, before, '-')
		if err != nil {
			return nil, err
		}
		advanced = advanced || truthy(deltas[key])
	}
	if !advanced {
		return []any{nil, current}, nil
	}
	return []any{deltas, current}, nil
}

func pollSharesToRecord(request Request) (any, error) {
	values, err := detailArguments(request, 2)
	if err != nil {
		return nil, err
	}
	if values[0] == nil {
		return []any{json.Number("0"), values[1]}, nil
	}
	last, _, err := pollNumber(values[0])
	if err != nil {
		return nil, err
	}
	current, _, err := pollNumber(values[1])
	if err != nil {
		return nil, err
	}
	if current.Cmp(last) <= 0 {
		baseline := values[0]
		if current.Cmp(last) < 0 {
			baseline = values[1]
		}
		return []any{json.Number("0"), baseline}, nil
	}
	delta, err := pollArithmetic(values[1], values[0], '-')
	if err != nil {
		return nil, err
	}
	return []any{delta, values[1]}, nil
}
