package resources

import "errors"

type resourceSpec struct {
	unit   any
	source any
}

var resourceSpecs = map[string]resourceSpec{
	"cpu":         {"percent", "proc_stat"},
	"load":        {"runnable_or_waiting_tasks", "getloadavg"},
	"memory":      {"bytes", "proc_meminfo"},
	"filesystem":  {"bytes", "data_filesystem"},
	"hugepages":   {"pages", "proc_meminfo"},
	"swap":        {"bytes", nil},
	"temperature": {"degrees_celsius", nil},
	"smart":       {nil, nil},
	"io_latency":  {"seconds", nil},
	"containers":  {nil, nil},
}

func buildHostResources(request Request) (map[string]any, error) {
	if len(request.Args) < 2 || len(request.Args) > 3 {
		return nil, errors.New("build_host_resources expects two or three arguments")
	}
	sampleValue, err := decode(request.Args[0])
	if err != nil {
		return nil, err
	}
	rowsValue, err := decode(request.Args[1])
	if err != nil {
		return nil, err
	}
	rows, ok := rowsValue.([]any)
	if !ok {
		return nil, errors.New("disk rows must be a list")
	}
	now, err := requestTime(request, 2)
	if err != nil {
		return nil, err
	}
	maxAge := request.MaxAge
	if maxAge <= 0 {
		maxAge = 90
	}
	samples := mapValue(sampleValue)
	result := make(map[string]any, len(resourceSpecs)+1)
	for name, spec := range resourceSpecs {
		result[name] = buildResource(name, spec, samples[name], now, maxAge)
	}
	outlook, err := capacityOutlook(rows, result["filesystem"].(map[string]any), now)
	if err != nil {
		return nil, err
	}
	result["capacity_outlook"] = outlook
	return result, nil
}

func requestTime(request Request, index int) (float64, error) {
	if len(request.Args) <= index {
		return request.Now, nil
	}
	value, err := decode(request.Args[index])
	if err != nil {
		return 0, err
	}
	if value == nil {
		return request.Now, nil
	}
	if boolean, ok := value.(bool); ok {
		if boolean {
			return 1, nil
		}
		return 0, nil
	}
	now, ok := number(value)
	if !ok {
		return 0, errors.New("time must be a finite number")
	}
	return now, nil
}

func buildResource(name string, spec resourceSpec, raw any, now, maxAge float64) map[string]any {
	sample := mapValue(raw)
	sampledAt := sample["sampled_at"]
	timestamp, validTimestamp := number(sampledAt)
	validTimestamp = validTimestamp && timestamp > 0
	var age any
	if validTimestamp && now-timestamp >= 0 {
		age = now - timestamp
	}
	reason := sample["reason"]
	switch {
	case spec.source == nil:
		reason = "unsupported"
	case !validTimestamp:
		reason = "missing"
	case now-timestamp < 0:
		reason = "clock_changed"
	case now-timestamp > maxAge:
		reason = "stale"
	case !validValue(name, sample["value"]):
		if !truthy(reason) {
			reason = "invalid_sample"
		}
	}
	value := sample["value"]
	state := "available"
	if truthy(reason) {
		state = "unavailable"
		value = nil
	}
	if !validTimestamp {
		sampledAt = nil
	}
	return map[string]any{
		"state": state, "reason": reason, "sampled_at": sampledAt, "age_seconds": age,
		"value": value, "unit": spec.unit, "source": spec.source,
	}
}

func validValue(name string, value any) bool {
	if name == "cpu" {
		n, ok := number(value)
		return ok && n >= 0 && n <= 100
	}
	if name == "load" {
		values, ok := value.([]any)
		if !ok || len(values) != 3 {
			return false
		}
		for _, value := range values {
			n, ok := number(value)
			if !ok || n < 0 {
				return false
			}
		}
		return true
	}
	values, ok := value.(map[string]any)
	if !ok {
		return false
	}
	total, totalOK := parseNumeric(values["total"])
	used, usedOK := parseNumeric(values["used"])
	if !totalOK || !usedOK || !nonnegative(total) || !nonnegative(used) || greater(used, total) || name != "hugepages" && zero(total) {
		return false
	}
	remainder := ""
	if name == "memory" {
		remainder = "available"
	} else if name == "hugepages" {
		remainder = "free"
	}
	if remainder == "" {
		return true
	}
	remaining, ok := parseNumeric(values[remainder])
	return ok && nonnegative(remaining) && sumEquals(used, remaining, total)
}

func buildCapacityOutlook(request Request) (map[string]any, error) {
	if len(request.Args) != 3 {
		return nil, errors.New("capacity_outlook expects three arguments")
	}
	rowsValue, err := decode(request.Args[0])
	if err != nil {
		return nil, err
	}
	rows, ok := rowsValue.([]any)
	if !ok {
		return nil, errors.New("rows must be a list")
	}
	filesystemValue, err := decode(request.Args[1])
	if err != nil {
		return nil, err
	}
	now, err := requestTime(Request{Args: request.Args, Now: request.Now}, 2)
	if err != nil {
		return nil, err
	}
	return capacityOutlook(rows, mapValue(filesystemValue), now)
}
