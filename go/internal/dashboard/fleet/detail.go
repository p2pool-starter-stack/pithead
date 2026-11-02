package fleet

import (
	"encoding/json"
	"errors"
	"math"
	"sort"
	"time"
)

func buildWorkerDetail(request Request) (any, error) {
	values, err := detailArguments(request, 1)
	if err != nil {
		return nil, err
	}
	envelope, err := object(values[0])
	if err != nil {
		return nil, err
	}
	for _, key := range []string{
		"name", "data", "descriptor", "history", "hashrate_by_config", "matched", "last_applied",
		"revision_drift", "worker_history", "marker_history", "range_arg", "window", "control_enabled", "writable_keys",
	} {
		if _, ok := envelope[key]; !ok {
			return nil, errors.New("missing worker detail " + key)
		}
	}
	name, ok := envelope["name"].(string)
	if !ok {
		return nil, errors.New("expected worker name")
	}
	data := map[string]any{}
	if envelope["data"] != nil {
		data, err = object(envelope["data"])
		if err != nil {
			return nil, err
		}
	}
	var descriptor map[string]any
	if envelope["descriptor"] != nil {
		descriptor, err = object(envelope["descriptor"])
		if err != nil {
			return nil, err
		}
	}
	historyUnread := envelope["history"] == nil
	history, err := detailRows(envelope["history"])
	if err != nil {
		return nil, err
	}
	byConfig, err := detailRows(envelope["hashrate_by_config"])
	if err != nil {
		return nil, err
	}
	location, err := detailZone(request.Zone)
	if err != nil {
		return nil, err
	}
	for _, row := range history {
		row["applied_at"] = detailAppliedAt(member(row, "ts", nil), location)
	}
	for _, row := range byConfig {
		row["applied_at"] = detailAppliedAt(member(row, "ts", nil), location)
		for _, key := range []string{"avg_h15", "min_h15", "max_h15"} {
			if row[key] != nil {
				row[key], err = formatDetailHashrate(row[key])
				if err != nil {
					return nil, err
				}
			}
		}
	}
	worker, err := findDetailWorker(data, name)
	if err != nil {
		return nil, err
	}
	var rigConfig, rigMeta, display, update any
	if worker != nil {
		rigforge := member(worker, "rigforge", nil)
		if truthy(rigforge) {
			rf, err := object(rigforge)
			if err != nil {
				return nil, err
			}
			rigConfig, rigMeta = member(rf, "config", nil), member(rf, "config_meta", nil)
			display, err = rigforgeDisplay(rf, member(worker, "status", nil) == "online", request.Now)
			if err != nil {
				return nil, err
			}
		}
		release := member(data, "rigforge_release", nil)
		if truthy(release) {
			releaseObject, err := object(release)
			if err != nil {
				return nil, err
			}
			update, err = rigforgeUpdate(worker, releaseObject, request.Now)
			if err != nil {
				return nil, err
			}
		}
	}
	matchedKnown, matchedStatus, matchedUnread, err := detailMatched(envelope["matched"])
	if err != nil {
		return nil, err
	}
	controlEnabled, ok := envelope["control_enabled"].(bool)
	if !ok {
		return nil, errors.New("expected control enabled boolean")
	}
	writable, err := detailStrings(envelope["writable_keys"])
	if err != nil {
		return nil, err
	}
	sort.Strings(writable)
	hashrateHistory, err := workerHashrateHistory([]any{
		envelope["worker_history"], envelope["marker_history"], envelope["range_arg"], envelope["window"],
	}, request)
	if err != nil {
		return nil, err
	}
	unsettled := hasUnsettledApply(historyToAny(history))
	if err := validateDriftBounds(envelope["last_applied"], rigConfig, unsettled); err != nil {
		return nil, err
	}
	result := map[string]any{
		"name": name, "snapshot_at": member(data, "timestamp", nil), "found": worker != nil,
		"editable": descriptor != nil && truthy(member(descriptor, "host", nil)), "control_enabled": controlEnabled,
		"ip": nil, "status": nil, "hashrate": nil, "rigforge": display, "rigforge_update": update,
		"writable_keys": writable, "rig_config": rigConfig, "rig_config_meta": rigMeta,
		"config_origin":         configOrigin(rigMeta, matchedKnown, matchedStatus, matchedUnread || historyUnread),
		"last_applied":          envelope["last_applied"],
		"config_drift":          configDrift(envelope["last_applied"], rigConfig, unsettled),
		"config_revision_drift": envelope["revision_drift"], "history": rowsToAny(history),
		"hashrate_by_config": rowsToAny(byConfig), "hashrate_history": hashrateHistory,
	}
	if worker != nil {
		result["ip"], result["status"] = member(worker, "ip", nil), member(worker, "status", nil)
		result["hashrate"], err = formatDetailHashrate(member(worker, "h60", json.Number("0")))
		if err != nil {
			return nil, err
		}
	}
	return result, nil
}

func detailRows(value any) ([]map[string]any, error) {
	if value == nil {
		return []map[string]any{}, nil
	}
	items, ok := value.([]any)
	if !ok {
		return nil, errors.New("expected detail rows")
	}
	rows := make([]map[string]any, 0, len(items))
	for _, item := range items {
		row, ok := item.(map[string]any)
		if !ok {
			return nil, errors.New("expected detail row")
		}
		rows = append(rows, row)
	}
	return rows, nil
}

func findDetailWorker(data map[string]any, name string) (map[string]any, error) {
	workers := member(data, "workers", []any{})
	items, ok := workers.([]any)
	if !ok {
		return nil, errors.New("expected workers")
	}
	for _, item := range items {
		worker, ok := item.(map[string]any)
		if !ok {
			return nil, errors.New("expected worker")
		}
		if member(worker, "name", nil) == name {
			return worker, nil
		}
	}
	return nil, nil
}

func detailMatched(value any) (bool, any, bool, error) {
	if value == nil {
		return false, nil, true, nil
	}
	row, ok := value.(map[string]any)
	if !ok {
		return false, nil, false, errors.New("expected matched row")
	}
	return len(row) != 0, member(row, "status", nil), false, nil
}

func detailStrings(value any) ([]string, error) {
	items, ok := value.([]any)
	if !ok {
		return nil, errors.New("expected writable keys")
	}
	result := make([]string, len(items))
	for index, item := range items {
		text, ok := item.(string)
		if !ok {
			return nil, errors.New("expected writable key")
		}
		result[index] = text
	}
	return result, nil
}

func detailZone(name string) (*time.Location, error) {
	if name == "" {
		return time.Local, nil
	}
	return time.LoadLocation(name)
}

func detailAppliedAt(value any, location *time.Location) string {
	if !truthy(value) {
		return ""
	}
	timestamp, ok := numeric(value)
	if !ok || timestamp >= math.MaxInt64 || timestamp < math.MinInt64 {
		return "Invalid Time"
	}
	seconds, fraction := math.Modf(timestamp)
	return time.Unix(int64(seconds), int64(fraction*1e9)).In(location).Format("15:04:05")
}

func rowsToAny(rows []map[string]any) []any {
	result := make([]any, len(rows))
	for index := range rows {
		result[index] = rows[index]
	}
	return result
}

func historyToAny(rows []map[string]any) any {
	return rowsToAny(rows)
}
