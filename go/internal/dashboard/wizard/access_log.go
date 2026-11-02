package wizard

import (
	"math"
	"math/big"
	"sort"
	"strconv"
)

type auditAccessRow struct {
	value  *ConfigValue
	ts     float64
	status int
	probe  string
}

func auditAccess(arguments *ConfigValue) (*ConfigValue, error) {
	available, err := auditField(arguments, "available")
	if err != nil {
		return nil, err
	}
	if available.Kind != "bool" {
		return nil, configTypeError{"available must be a bool"}
	}
	if !available.Bool {
		return auditAccessResult(false, nil, 0, nil, false), nil
	}
	entries, err := auditField(arguments, "entries")
	if err != nil {
		return nil, err
	}
	now, err := auditField(arguments, "now")
	if err != nil {
		return nil, err
	}
	limit, err := auditField(arguments, "limit")
	if err != nil {
		return nil, err
	}
	threshold, err := auditField(arguments, "threshold")
	if err != nil {
		return nil, err
	}
	methods, err := auditField(arguments, "methods")
	if err != nil {
		return nil, err
	}
	if entries.Kind != "list" {
		return nil, configTypeError{"entries must be a list"}
	}
	nowFloat, err := auditAccessNumber(now, "now")
	if err != nil {
		return nil, err
	}
	if !numericKind(threshold.Kind) {
		return nil, configTypeError{"threshold must be a number"}
	}
	knownMethods, err := auditAccessMethods(methods)
	if err != nil {
		return nil, err
	}
	rows := make([]auditAccessRow, len(entries.Items))
	for index, entry := range entries.Items {
		row, rowErr := auditAccessEntry(entry, knownMethods)
		if rowErr != nil {
			return nil, rowErr
		}
		rows[index] = row
	}
	failures := 0
	var lastFailure *ConfigValue
	lastFailureFloat := 0.0
	for _, row := range rows {
		difference := nowFloat - row.ts
		if row.status == 401 && difference >= 0 && difference <= 86400 && row.probe != "boot-health-v1" {
			failures++
			if lastFailure == nil || row.ts > lastFailureFloat {
				ts, _ := row.value.Field("ts")
				lastFailure = ts.Clone()
				lastFailureFloat = row.ts
			}
		}
	}
	sort.SliceStable(rows, func(left, right int) bool { return rows[left].ts > rows[right].ts })
	end, err := auditSliceEnd(limit, len(rows))
	if err != nil {
		return nil, err
	}
	selected := make([]*ConfigValue, end)
	for index := 0; index < end; index++ {
		selected[index] = rows[index].value
	}
	comparison, comparable := auditNumberCompare(&ConfigValue{Kind: "int", Text: strconv.Itoa(failures)}, threshold)
	return auditAccessResult(true, selected, failures, lastFailure, comparable && comparison >= 0), nil
}

func auditAccessEntry(entry *ConfigValue, methods map[string]struct{}) (auditAccessRow, error) {
	if entry == nil || entry.Kind != "dict" {
		return auditAccessRow{}, configTypeError{"access entries must be objects"}
	}
	ts, ok := entry.Field("ts")
	if !ok || ts.Kind != "float" {
		return auditAccessRow{}, configTypeError{"access entry ts must be a float"}
	}
	tsFloat, err := parseFloat(ts.Text)
	if err != nil {
		return auditAccessRow{}, err
	}
	if math.IsNaN(tsFloat) || math.IsInf(tsFloat, 0) {
		ts = &ConfigValue{Kind: "float", Text: "0"}
		tsFloat = 0
	} else {
		ts = ts.Clone()
	}
	status, ok := entry.Field("status")
	if !ok || status.Kind != "int" {
		return auditAccessRow{}, configTypeError{"access entry status must be an int"}
	}
	statusInt, ok := new(big.Int).SetString(status.Text, 10)
	if !ok {
		return auditAccessRow{}, configTypeError{"access entry status must be an int"}
	}
	statusValue := 0
	if statusInt.IsInt64() {
		candidate := statusInt.Int64()
		if candidate >= 100 && candidate <= 599 {
			statusValue = int(candidate)
		}
	}
	method, ok := entry.Field("method")
	if !ok || method.Kind != "str" && method.Kind != "null" {
		return auditAccessRow{}, configTypeError{"access entry method must be a string or None"}
	}
	methodText := "?"
	if method.Kind == "str" {
		if _, known := methods[method.Text]; known {
			methodText = method.Text
		}
	}
	uri, err := auditAccessText(entry, "uri")
	if err != nil {
		return auditAccessRow{}, err
	}
	user, err := auditAccessText(entry, "user")
	if err != nil {
		return auditAccessRow{}, err
	}
	probe, ok := entry.Field("probe")
	if !ok || probe.Kind != "str" && probe.Kind != "null" {
		return auditAccessRow{}, configTypeError{"access entry probe must be a string or None"}
	}
	probeText := ""
	if probe.Kind == "str" {
		probeText = probe.Text
	}
	cleanURI, err := auditClean(uri, 200)
	if err != nil {
		return auditAccessRow{}, err
	}
	cleanUser, err := auditClean(user, 64)
	if err != nil {
		return auditAccessRow{}, err
	}
	value := editorDict(
		editorField("ts", ts),
		editorField("status", &ConfigValue{Kind: "int", Text: strconv.Itoa(statusValue)}),
		editorField("method", configString(methodText)),
		editorField("uri", configString(cleanURI)),
		editorField("user", configString(cleanUser)),
	)
	return auditAccessRow{value: value, ts: tsFloat, status: statusValue, probe: probeText}, nil
}

func auditAccessMethods(value *ConfigValue) (map[string]struct{}, error) {
	if value.Kind != "list" {
		return nil, configTypeError{"methods must be a list"}
	}
	methods := make(map[string]struct{}, len(value.Items))
	for _, method := range value.Items {
		if method == nil || method.Kind != "str" {
			return nil, configTypeError{"methods must contain strings"}
		}
		methods[method.Text] = struct{}{}
	}
	return methods, nil
}

func auditAccessNumber(value *ConfigValue, name string) (float64, error) {
	if value == nil || !numericKind(value.Kind) {
		return 0, configTypeError{name + " must be a number"}
	}
	if value.Kind == "float" {
		result, err := parseFloat(value.Text)
		if err != nil {
			return 0, err
		}
		return result, nil
	}
	integer, ok := configInteger(value)
	if !ok || integer.BitLen() > 1023 {
		return 0, configTypeError{name + " is outside the native numeric range"}
	}
	result, _ := integer.Float64()
	return result, nil
}

func auditAccessText(entry *ConfigValue, name string) (*ConfigValue, error) {
	value, ok := entry.Field(name)
	if !ok || value.Kind != "str" {
		return nil, configTypeError{"access entry " + name + " must be a string"}
	}
	return value, nil
}

func auditAccessResult(available bool, entries []*ConfigValue, failures int, lastFailure *ConfigValue, rotate bool) *ConfigValue {
	if entries == nil {
		entries = []*ConfigValue{}
	}
	if lastFailure == nil {
		lastFailure = &ConfigValue{Kind: "null"}
	}
	return editorDict(
		editorField("available", &ConfigValue{Kind: "bool", Bool: available}),
		editorField("entries", &ConfigValue{Kind: "list", Items: entries}),
		editorField("failures_24h", &ConfigValue{Kind: "int", Text: strconv.Itoa(failures)}),
		editorField("last_failure_ts", lastFailure),
		editorField("rotate_hint", &ConfigValue{Kind: "bool", Bool: rotate}),
	)
}
