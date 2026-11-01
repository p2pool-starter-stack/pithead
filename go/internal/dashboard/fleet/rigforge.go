package fleet

import (
	"encoding/json"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"time"
)

type rigforgeRow struct {
	label   string
	value   string
	chip    string
	variant string
	title   string
	listed  map[string]string
}

func buildRigforgeDisplay(raw []json.RawMessage, now float64) (any, error) {
	values, err := arguments(raw, 2)
	if err != nil {
		return nil, err
	}
	proxyOnline, ok := values[1].(bool)
	if !ok {
		return nil, errors.New("expected proxy online boolean")
	}
	if !truthy(values[0]) {
		return nil, nil
	}
	rf, err := object(values[0])
	if err != nil {
		return nil, err
	}
	return rigforgeDisplay(rf, proxyOnline, now)
}

func rigforgeDisplay(rf map[string]any, proxyOnline bool, now float64) (any, error) {
	age, fresh := feedAge(member(rf, "generated_at", nil), now)
	if !fresh || age > 60 {
		var staleAge any
		if fresh {
			staleAge = json.Number(fmtNumber(age))
		}
		if _, present := rf["generated_at"]; !present {
			staleAge = member(rf, "age_sec", nil)
		}
		value := "freshness unknown"
		title := "This RigForge report has no valid generation stamp, so its live agent version, miner state, temperature and health cannot be trusted."
		if staleAge != nil {
			duration := formatDuration(staleAge)
			value = "stale for " + duration
			title = "RigForge's report is " + duration + " old. Live agent version, miner state, temperature and health are hidden until a current report arrives."
		}
		return map[string]any{
			"generated_at": member(rf, "generated_at", nil), "stale": true, "version": nil,
			"miner_down": false,
			"chips":      []any{map[string]any{"text": "agent " + value, "variant": "warn", "title": title}},
			"stats":      []any{map[string]any{"label": "Agent report", "value": value, "variant": "warn", "title": title}},
		}, nil
	}
	rows := make([]rigforgeRow, 0)
	add := func(label, value, chip, variant, title string, listed map[string]string) {
		if listed == nil && (variant == "warn" || variant == "bad") {
			listed = map[string]string{}
		}
		rows = append(rows, rigforgeRow{label, value, chip, variant, title, listed})
	}
	if truthy(member(rf, "miner_down", false)) {
		if proxyOnline {
			add("Miner", "agent reports down", "agent reports miner down", "warn", "The current RigForge report cannot reach XMRig, but the proxy still sees this worker connected and accepting shares. Proxy-observed mining state wins.", nil)
		} else {
			add("Miner", "down", "miner down", "bad", "RigForge is up but its XMRig API is unreachable, and the proxy does not see the worker online.", nil)
		}
	}
	health, err := optionalObject(rf, "health")
	if err != nil {
		return nil, err
	}
	if value, ok := health["throttling"].(bool); ok && value {
		add("CPU", "throttling", "throttling", "bad", "CPU is thermal/power throttling.", nil)
	}
	if governor := member(health, "governor", nil); truthy(governor) {
		text, ok := governor.(string)
		if !ok {
			return nil, errors.New("expected governor string")
		}
		variant, suffix := "warn", " — 'performance' is recommended for mining."
		if text == "performance" {
			variant, suffix = "ok", ""
		}
		add("Governor", text, "gov: "+text, variant, "CPU frequency governor"+suffix, nil)
	}
	if hugepages := member(health, "hugepages_total", nil); isPythonNumber(hugepages) {
		text, err := fmtNumeric(hugepages)
		if err != nil {
			return nil, err
		}
		add("HugePages", text, "HP "+text, "outline", "HugePages allocated: "+text+".", nil)
	}
	if board := member(health, "board", nil); truthy(board) {
		text, ok := board.(string)
		if !ok {
			return nil, errors.New("expected board string")
		}
		add("Mainboard", text, text, "outline", "Mainboard (firmware).", nil)
	}
	power, err := optionalObject(rf, "power")
	if err != nil {
		return nil, err
	}
	watts, haveWatts := member(power, "watts", nil), isPythonNumber(member(power, "watts", nil))
	efficiency, haveEfficiency := member(power, "hs_per_watt", nil), isPythonNumber(member(power, "hs_per_watt", nil))
	if haveWatts || haveEfficiency {
		parts := make([]string, 0, 2)
		if haveWatts {
			text, err := roundedNumeric(watts, 1)
			if err != nil {
				return nil, err
			}
			parts = append(parts, text+" W")
		}
		if haveEfficiency {
			text, err := roundedNumeric(efficiency, 1)
			if err != nil {
				return nil, err
			}
			parts = append(parts, text+" H/s·W")
		}
		text := strings.Join(parts, " · ")
		add("Power / efficiency", text, text, "outline", "Power draw / efficiency.", map[string]string{"text": parts[0], "title": "Power draw / efficiency: " + text})
	}
	tune, err := optionalObject(rf, "tune")
	if err != nil {
		return nil, err
	}
	if target := member(tune, "target", nil); truthy(target) {
		text, ok := target.(string)
		if !ok {
			return nil, errors.New("expected tuning target string")
		}
		add("Tuning target", text, "tune: "+text, "outline", "Active tuning target.", nil)
	}
	if truthy(member(tune, "autotune_enabled", false)) && truthy(member(tune, "autotune_next", nil)) {
		text, ok := tune["autotune_next"].(string)
		if !ok {
			return nil, errors.New("expected autotune time string")
		}
		add("Autotune", text, "autotune → "+text, "outline", "Next scheduled autotune run.", nil)
	}
	watchdog, err := optionalObject(rf, "watchdog")
	if err != nil {
		return nil, err
	}
	if truthy(member(watchdog, "enabled", false)) {
		temperature, haveTemperature := member(watchdog, "temp_c", nil), isPythonNumber(member(watchdog, "temp_c", nil))
		maximum, haveMaximum := member(watchdog, "max_temp_c", nil), isPythonNumber(member(watchdog, "max_temp_c", nil))
		if value, ok := watchdog["thermal_hold"].(bool); ok && value {
			add("Watchdog", "thermal hold", "thermal hold", "bad", "Watchdog is holding the rig back — temperature above its ceiling.", nil)
		} else if haveTemperature {
			shortValue, err := roundedNumeric(temperature, 1)
			if err != nil {
				return nil, err
			}
			short := shortValue + "°C"
			text := short
			if haveMaximum {
				maximumText, err := fmtNumeric(maximum)
				if err != nil {
					return nil, err
				}
				text += " / " + maximumText + "°C"
			}
			add("Temp / max", text, text, "outline", "Watchdog temperature / ceiling.", map[string]string{"text": short, "title": "Watchdog temperature / ceiling: " + text})
		}
	}
	chips := make([]any, 0)
	stats := make([]any, 0, len(rows))
	for _, row := range rows {
		if row.listed != nil {
			text, title := row.chip, row.title
			if value, ok := row.listed["text"]; ok {
				text = value
			}
			if value, ok := row.listed["title"]; ok {
				title = value
			}
			chips = append(chips, map[string]any{"text": text, "variant": row.variant, "title": title})
		}
		stats = append(stats, map[string]any{"label": row.label, "value": row.value, "variant": row.variant, "title": row.title})
	}
	return map[string]any{"generated_at": member(rf, "generated_at", nil), "stale": false, "version": member(rf, "version", nil), "miner_down": truthy(member(rf, "miner_down", false)), "chips": chips, "stats": stats}, nil
}

func optionalObject(parent map[string]any, key string) (map[string]any, error) {
	value := member(parent, key, nil)
	if !truthy(value) {
		return map[string]any{}, nil
	}
	return object(value)
}

func feedAge(value any, now float64) (float64, bool) {
	stamp, ok := value.(string)
	if !ok {
		return 0, false
	}
	stamp, ok = normalizeUTCStamp(stamp)
	if !ok {
		return 0, false
	}
	generated, err := time.Parse("2006-01-02T15:04:05Z", stamp)
	if err != nil {
		return 0, false
	}
	age := now - float64(generated.Unix())
	if age < -60 {
		return 0, false
	}
	return mathRoundEvenMaximum(age), true
}

func normalizeUTCStamp(value string) (string, bool) {
	value = strings.ToUpper(value)
	date, clock, ok := strings.Cut(value, "T")
	if !ok || !strings.HasSuffix(clock, "Z") {
		return "", false
	}
	dateParts := strings.Split(date, "-")
	clockParts := strings.Split(strings.TrimSuffix(clock, "Z"), ":")
	if len(dateParts) != 3 || len(clockParts) != 3 {
		return "", false
	}
	parts := append(dateParts, clockParts...)
	values := make([]int, 6)
	for index, part := range parts {
		if index == 2 && len(part) == 2 && part[0] == ' ' {
			part = part[1:]
		}
		if index == 0 && len(part) != 4 || index != 0 && (len(part) < 1 || len(part) > 2) {
			return "", false
		}
		for _, digit := range part {
			if digit < '0' || digit > '9' {
				return "", false
			}
		}
		values[index], _ = strconv.Atoi(part)
	}
	if values[0] == 0 {
		return "", false
	}
	return fmt.Sprintf("%04d-%02d-%02dT%02d:%02d:%02dZ", values[0], values[1], values[2], values[3], values[4], values[5]), true
}

func mathRoundEvenMaximum(value float64) float64 {
	if value < 0 {
		return 0
	}
	return pythonRound(value, 0)
}

func buildNum(raw []json.RawMessage) (any, error) {
	values, err := arguments(raw, 1)
	if err != nil {
		return nil, err
	}
	if integer, ok := integerNumber(values[0]); ok {
		return json.Number(integer.String()), nil
	}
	if number, ok := numeric(values[0]); ok {
		return number, nil
	}
	return nil, nil
}

func buildFmt(raw []json.RawMessage) (any, error) {
	values, err := arguments(raw, 1)
	if err != nil {
		return nil, err
	}
	if isPythonNumber(values[0]) {
		return fmtNumeric(values[0])
	}
	switch values[0].(type) {
	case nil, bool, string:
		return pythonString(values[0]), nil
	default:
		return nil, errors.New("unsupported Python string value")
	}
}

func isPythonNumber(value any) bool {
	_, ok := value.(json.Number)
	return ok
}
