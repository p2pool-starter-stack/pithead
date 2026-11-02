package fleet

import (
	"encoding/json"
	"fmt"
	"math"
	"math/big"
	"strings"
	"unicode"

	"github.com/p2pool-starter-stack/pithead/go/internal/dashboard/control"
)

func pollParseRigforge(request Request) (any, error) {
	values, err := detailArguments(request, 2)
	if err != nil {
		return nil, err
	}
	return parseRigforge(values[0], values[1])
}

func pollMergeRigforgeStats(request Request) (any, error) {
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
	clocks, err := array(values[3])
	if err != nil {
		return nil, err
	}
	count := min(len(workers), len(results))
	if len(clocks) != count {
		return nil, pollValueError("RigForge clocks length must match worker result count")
	}
	rigforge := make([]any, count)
	for index := 0; index < count; index++ {
		if !truthy(results[index]) {
			continue
		}
		rigforge[index], err = parseRigforge(results[index], clocks[index])
		if err != nil {
			return nil, err
		}
	}
	return mergeDirectStats([]any{workers, results, values[2], rigforge})
}

func parseRigforge(payloadValue, nowValue any) (any, error) {
	payload, ok := payloadValue.(map[string]any)
	if !ok {
		return nil, nil
	}
	rf, ok := payload["rigforge"].(map[string]any)
	if !ok {
		return nil, nil
	}
	age, fresh, err := rigforgeFeedAge(member(payload, "generated_at", nil), nowValue)
	if err != nil {
		return nil, err
	}
	tune, err := rigforgeOptionalObject(rf, "tune")
	if err != nil {
		return nil, err
	}
	autotune, err := rigforgeOptionalObject(tune, "autotune")
	if err != nil {
		return nil, err
	}
	power, err := rigforgeOptionalObject(rf, "power")
	if err != nil {
		return nil, err
	}
	health, err := rigforgeOptionalObject(rf, "health")
	if err != nil {
		return nil, err
	}
	firmware, err := rigforgeOptionalObject(health, "firmware")
	if err != nil {
		return nil, err
	}
	watchdog, err := rigforgeOptionalObject(rf, "watchdog")
	if err != nil {
		return nil, err
	}
	watchdogEnabled := member(watchdog, "mode", nil) == "enabled"
	var stamp any
	var ageValue any
	if fresh {
		stamp = member(payload, "generated_at", nil)
		ageValue = age
	}
	result := map[string]any{
		"generated_at": stamp,
		"age_sec":      ageValue,
		"stale":        !fresh || rigforgeAgeStale(age),
		"version":      member(rf, "version", nil),
		"miner_down":   member(rf, "xmrig_api", nil) == "unreachable",
		"power": map[string]any{
			"watts": member(power, "watts", nil), "hs_per_watt": member(power, "hs_per_watt", nil),
		},
		"tune": map[string]any{
			"target": member(tune, "target", nil), "autotune_enabled": truthy(member(autotune, "enabled", nil)),
			"autotune_next": member(autotune, "next", nil),
		},
		"health": map[string]any{
			"governor": member(health, "governor", nil), "throttling": member(health, "throttling", nil),
			"board": member(firmware, "board", nil), "hugepages_total": member(health, "hugepages_total", nil),
		},
		"watchdog": map[string]any{
			"enabled": watchdogEnabled, "thermal_hold": nil, "temp_c": nil, "max_temp_c": nil,
		},
		"config":      rigforgeWritableConfig(member(rf, "config", nil)),
		"config_meta": normalizeRigforgeConfigMeta(member(rf, "config_meta", nil)),
	}
	if watchdogEnabled {
		result["watchdog"] = map[string]any{
			"enabled": true, "thermal_hold": member(watchdog, "thermal_hold", nil),
			"temp_c": member(watchdog, "temp_c", nil), "max_temp_c": member(watchdog, "max_temp_c", nil),
		}
	}
	return result, nil
}

func rigforgeOptionalObject(parent map[string]any, key string) (map[string]any, error) {
	value := member(parent, key, nil)
	if !truthy(value) {
		return map[string]any{}, nil
	}
	result, ok := value.(map[string]any)
	if !ok {
		return nil, &PollError{Kind: "AttributeError", Message: fmt.Sprintf("'%s' object has no attribute 'get'", rigforgePythonType(value))}
	}
	return result, nil
}

func rigforgePythonType(value any) string {
	switch value := value.(type) {
	case string:
		return "str"
	case bool:
		return "bool"
	case float64:
		return "float"
	case json.Number:
		if strings.ContainsAny(value.String(), ".eE") {
			return "float"
		}
		return "int"
	case []any:
		return "list"
	case map[string]any:
		return "dict"
	case nil:
		return "NoneType"
	default:
		return "object"
	}
}

func rigforgeFeedAge(stamp, now any) (any, bool, error) {
	generated, ok := feedGeneratedUnix(stamp)
	if !ok {
		return nil, false, nil
	}
	var current float64
	switch value := now.(type) {
	case json.Number:
		if integer, ok := integerNumber(value); ok {
			current, _ = integer.Float64()
			if math.IsInf(current, 0) {
				return nil, false, &PollError{Kind: "OverflowError", Message: "int too large to convert to float"}
			}
		} else {
			var err error
			current, err = value.Float64()
			if err != nil && !math.IsInf(current, 0) {
				return nil, false, nil
			}
		}
	case float64:
		current = value
	case bool:
		if value {
			current = 1
		}
	default:
		return 0, false, nil
	}
	if math.IsNaN(current) || math.IsInf(current, -1) {
		return nil, false, nil
	}
	age := current - float64(generated)
	if age < -60 {
		return nil, false, nil
	}
	if math.IsInf(age, 1) {
		return nil, false, &PollError{Kind: "OverflowError", Message: "cannot convert float infinity to integer"}
	}
	if age < 0 {
		age = 0
	}
	rounded := pythonRound(age, 0)
	integer, _ := new(big.Float).SetFloat64(rounded).Int(nil)
	return json.Number(integer.String()), true, nil
}

func rigforgeAgeStale(value any) bool {
	integer, ok := integerNumber(value)
	return ok && integer.Cmp(big.NewInt(60)) > 0
}

func rigforgeWritableConfig(value any) any {
	config, ok := value.(map[string]any)
	if !ok {
		return nil
	}
	filtered := make(map[string]any)
	for key, item := range config {
		if control.WorkerWritableKey(key) {
			filtered[key] = item
		}
	}
	masked := maskCredentials(filtered, 0).(map[string]any)
	if len(masked) == 0 {
		return nil
	}
	return masked
}

func normalizeRigforgeConfigMeta(value any) any {
	meta, ok := value.(map[string]any)
	if !ok {
		return nil
	}
	revision := rigforgeToken(member(meta, "revision", nil))
	changedAt := rigforgeTimestamp(member(meta, "changed_at", nil))
	source := rigforgeSource(member(meta, "source", nil))
	changeID := rigforgeToken(member(meta, "last_change_id", nil))
	if revision == nil && changedAt == nil && source == nil && changeID == nil {
		return nil
	}
	return map[string]any{
		"revision": revision, "changed_at": changedAt, "source": source, "last_change_id": changeID,
	}
}

func rigforgeToken(value any) any {
	text, ok := value.(string)
	if !ok || text == "" || len(text) > 64 || !rigforgeTokenMatches(text) {
		return nil
	}
	return text
}

func rigforgeTimestamp(value any) any {
	text, ok := value.(string)
	if !ok || !rigforgeTimestampMatches(text) {
		return nil
	}
	return text
}

func rigforgeTokenMatches(value string) bool {
	match := strings.TrimSuffix(value, "\n")
	if match == "" {
		return false
	}
	for _, char := range match {
		if !('A' <= char && char <= 'Z') && !('a' <= char && char <= 'z') && !('0' <= char && char <= '9') && char != '.' && char != '_' && char != '-' {
			return false
		}
	}
	return true
}

func rigforgeTimestampMatches(value string) bool {
	match := []rune(strings.TrimSuffix(value, "\n"))
	if len(match) != 20 || match[4] != '-' || match[7] != '-' || match[10] != 'T' || match[13] != ':' || match[16] != ':' || match[19] != 'Z' {
		return false
	}
	for _, index := range []int{0, 1, 2, 3, 5, 6, 8, 9, 11, 12, 14, 15, 17, 18} {
		if !unicode.IsDigit(match[index]) {
			return false
		}
	}
	return true
}

func rigforgeSource(value any) any {
	if value == "control" || value == "local" || value == "restore" {
		return value
	}
	return nil
}
