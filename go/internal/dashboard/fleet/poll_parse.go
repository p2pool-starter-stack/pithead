package fleet

import (
	"encoding/json"
	"errors"
	"strings"
)

func pollParseProxyListWorker(request Request) (any, error) {
	values, err := detailArguments(request, 2)
	if err != nil {
		return nil, err
	}
	row, err := array(values[0])
	if err != nil {
		return nil, err
	}
	return parseProxyListWorker(row, values[1], request.Now)
}

func parseProxyListWorker(row []any, offlineValue any, now float64) (any, error) {
	if len(row) < 13 {
		return nil, errors.New("invalid proxy worker row")
	}
	offlineAfter, err := pollFloat(offlineValue)
	if err != nil {
		return nil, err
	}
	connections, err := pollCompare(row[2], 0)
	if err != nil {
		return nil, err
	}
	accepted, err := pollCompare(row[3], 0)
	if err != nil {
		return nil, err
	}
	lastShare, err := pollFloat(pollZero(row[7]))
	if err != nil {
		return nil, err
	}
	shareAge := now - lastShare/1000
	status := "offline"
	if connections > 0 || accepted > 0 && shareAge >= 0 && shareAge <= offlineAfter {
		status = "online"
	}
	rates := make([]any, 5)
	for index, source := range []int{8, 9, 10, 11, 12} {
		rates[index], err = pollArithmetic(row[source], json.Number("1000"), '*')
		if err != nil {
			return nil, err
		}
	}
	return map[string]any{
		"name": row[0], "ip": row[1], "status": status,
		"h10": rates[0], "h60": rates[0], "h15": rates[1],
		"h1h": rates[2], "h12h": rates[3], "h24h": rates[4],
		"uptime": json.Number("0"), "accepted": pollZero(row[3]),
		"rejected": pollZero(row[4]), "invalid": pollZero(row[5]),
	}, nil
}

func pollParseLegacyDictWorker(request Request) (any, error) {
	values, err := detailArguments(request, 1)
	if err != nil {
		return nil, err
	}
	row, err := object(values[0])
	if err != nil {
		return nil, err
	}
	return parseLegacyDictWorker(row)
}

func parseLegacyDictWorker(row map[string]any) (any, error) {
	hashrate := []any{}
	value := member(row, "hashrate", []any{json.Number("0"), json.Number("0"), json.Number("0")})
	var err error
	hashrate, err = array(value)
	if err != nil {
		return nil, err
	}
	rate := func(index int) any {
		if index < len(hashrate) {
			return hashrate[index]
		}
		return json.Number("0")
	}
	longRate := rate(2)
	if len(hashrate) > 0 && len(hashrate) <= 2 {
		longRate = hashrate[len(hashrate)-1]
	}
	zeroAddress := strings.Repeat("0.", 3) + "0"
	return map[string]any{
		"name": member(row, "id", "Unknown"), "ip": member(row, "ip", zeroAddress),
		"status": "online", "h10": rate(0), "h60": rate(1), "h15": rate(2),
		"h1h": longRate, "h12h": longRate, "h24h": longRate,
		"uptime":   member(row, "uptime", json.Number("0")),
		"accepted": member(row, "accepted", json.Number("0")),
		"rejected": member(row, "rejected", json.Number("0")),
		"invalid":  member(row, "invalid", json.Number("0")),
	}, nil
}

func pollNormalizeProxyWorkers(request Request) (any, error) {
	values, err := detailArguments(request, 2)
	if err != nil {
		return nil, err
	}
	if !truthy(values[0]) {
		return []any{}, nil
	}
	payload, err := object(values[0])
	if err != nil {
		return nil, err
	}
	rawWorkers, ok := payload["workers"]
	if !ok {
		return nil, pollValueError("Proxy workers payload is missing workers")
	}
	workers, err := array(rawWorkers)
	if err != nil {
		return nil, err
	}
	result := make([]any, 0, len(workers))
	for _, raw := range workers {
		var parsed any
		switch row := raw.(type) {
		case []any:
			if len(row) < 13 {
				continue
			}
			parsed, err = parseProxyListWorker(row, values[1], request.Now)
		case map[string]any:
			parsed, err = parseLegacyDictWorker(row)
		default:
			continue
		}
		if err != nil {
			return nil, err
		}
		result = append(result, parsed)
	}
	return result, nil
}
