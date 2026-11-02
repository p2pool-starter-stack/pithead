package fleet

import (
	"encoding/json"
	"fmt"
)

func pollTelemetryHourly(request Request) (any, error) {
	values, err := detailArguments(request, 5)
	if err != nil {
		return nil, err
	}
	due, err := telemetryDue(values[0], values[1], values[2])
	if err != nil {
		return nil, err
	}
	if !due {
		return map[string]any{"due": false, "values": []any{}}, nil
	}
	monero, err := telemetryObject(values[3])
	if err != nil {
		return nil, err
	}
	disk := map[string]any{}
	if truthy(values[4]) {
		disk, err = telemetryObject(values[4])
		if err != nil {
			return nil, err
		}
	}
	return map[string]any{
		"due": true,
		"values": []any{
			pollZero(member(monero, "db_size", json.Number("0"))),
			pollZero(member(disk, "used_gb", json.Number("0"))),
			pollZero(member(disk, "total_gb", json.Number("0"))),
		},
	}, nil
}

func pollTelemetryNetwork(request Request) (any, error) {
	values, err := detailArguments(request, 2)
	if err != nil {
		return nil, err
	}
	network, err := telemetryObject(values[0])
	if err != nil {
		return nil, err
	}
	pool, err := telemetryObject(values[1])
	if err != nil {
		return nil, err
	}
	return []any{
		pollZero(member(network, "difficulty", json.Number("0"))),
		pollZero(member(network, "height", json.Number("0"))),
		pollZero(member(network, "reward", json.Number("0"))),
		pollZero(member(pool, "hashrate", json.Number("0"))),
	}, nil
}

func pollTelemetryWorkerDue(request Request) (any, error) {
	values, err := detailArguments(request, 3)
	if err != nil {
		return nil, err
	}
	return telemetryDue(values[0], values[1], values[2])
}

func pollTelemetryWorkers(request Request) (any, error) {
	values, err := detailArguments(request, 4)
	if err != nil {
		return nil, err
	}
	due, err := telemetryDue(values[0], values[1], values[2])
	if err != nil {
		return nil, err
	}
	if !due {
		return map[string]any{"due": false, "rows": []any{}}, nil
	}
	workers, err := array(values[3])
	if err != nil {
		return nil, err
	}
	rows := make([]any, 0, len(workers))
	for _, value := range workers {
		worker, err := telemetryObject(value)
		if err != nil {
			return nil, err
		}
		if member(worker, "status", nil) != "online" {
			continue
		}
		rows = append(rows, []any{
			values[0],
			member(worker, "name", ""),
			pollZero(member(worker, "h15", json.Number("0"))),
			pollZero(member(worker, "accepted", json.Number("0"))),
			pollZero(member(worker, "rejected", json.Number("0"))),
		})
	}
	return map[string]any{"due": true, "rows": rows}, nil
}

func telemetryDue(now, last, interval any) (bool, error) {
	delta, err := pollArithmetic(now, last, '-')
	if err != nil {
		return false, &PollError{Kind: "TypeError", Message: fmt.Sprintf("unsupported operand type(s) for -: '%s' and '%s'", rigforgePythonType(now), rigforgePythonType(last))}
	}
	left, leftOK := dynamicNumber(delta)
	right, rightOK := dynamicNumber(interval)
	if !leftOK || !rightOK {
		return false, &PollError{Kind: "TypeError", Message: fmt.Sprintf("'>=' not supported between instances of '%s' and '%s'", rigforgePythonType(delta), rigforgePythonType(interval))}
	}
	if left.nan || right.nan {
		return false, nil
	}
	if left.infinite != 0 || right.infinite != 0 {
		return left.infinite >= right.infinite, nil
	}
	return left.rat.Cmp(right.rat) >= 0, nil
}

func telemetryObject(value any) (map[string]any, error) {
	result, ok := value.(map[string]any)
	if !ok {
		return nil, &PollError{Kind: "AttributeError", Message: fmt.Sprintf("'%s' object has no attribute 'get'", rigforgePythonType(value))}
	}
	return result, nil
}
