package infra

import (
	"encoding/json"
	"fmt"
	"strings"
)

const healthTip = "Green means monerod is synchronized at the network tip with outgoing peers and its height has moved in the last 30 minutes (Monero blocks arrive about every 2). Red means it has had no outgoing peers for 10 minutes or its height has not moved for 30 minutes, with the numbers shown. Stale sync is also red; a syncing node has no at-tip verdict. A remote node's peers are not visible to this stack, so no verdict is given."

func buildSync(raw []json.RawMessage) (any, error) {
	args, err := arguments(raw, 2)
	if err != nil {
		return nil, err
	}
	metrics, err := object(args[0])
	if err != nil {
		return nil, err
	}
	moneroMetric, err := required(metrics, "monero")
	if err != nil {
		return nil, err
	}
	mode, err := required(metrics, "monero_mode")
	if err != nil {
		return nil, err
	}
	moneroLocal, err := required(metrics, "monero_local")
	if err != nil {
		return nil, err
	}
	monero, err := syncSection(moneroMetric, map[string]any{
		"mode": mode, "db_size": args[1], "local": moneroLocal,
	})
	if err != nil {
		return nil, err
	}
	tariMetric, err := required(metrics, "tari")
	if err != nil {
		return nil, err
	}
	tariLocal, err := required(metrics, "tari_local")
	if err != nil {
		return nil, err
	}
	tari, err := syncSection(tariMetric, map[string]any{"local": tariLocal})
	if err != nil {
		return nil, err
	}
	return map[string]any{"monero": monero, "tari": tari}, nil
}

func syncSection(value any, extra map[string]any) (map[string]any, error) {
	syncMetric, err := object(value)
	if err != nil {
		return nil, err
	}
	done, err := required(syncMetric, "done")
	if err != nil {
		return nil, err
	}
	hasTarget, err := required(syncMetric, "has_target")
	if err != nil {
		return nil, err
	}
	state := "syncing"
	if truthy(done) {
		state = "done"
	} else if !truthy(hasTarget) {
		state = "loading"
	}
	percent, err := required(syncMetric, "percent")
	if err != nil {
		return nil, err
	}
	current, err := required(syncMetric, "current")
	if err != nil {
		return nil, err
	}
	target, err := required(syncMetric, "target")
	if err != nil {
		return nil, err
	}
	remaining, err := required(syncMetric, "remaining")
	if err != nil {
		return nil, err
	}
	result := map[string]any{
		"state": state, "percent": percent, "current": current, "target": target, "remaining": remaining,
	}
	for key, item := range extra {
		result[key] = item
	}
	return result, nil
}

func buildMonero(raw []json.RawMessage) (any, error) {
	args, err := arguments(raw, 2)
	if err != nil {
		return nil, err
	}
	data, err := object(args[0])
	if err != nil {
		return nil, err
	}
	metrics, err := object(args[1])
	if err != nil {
		return nil, err
	}
	moneroSync, err := objectMember(data, "monero_sync")
	if err != nil {
		return nil, err
	}
	dbSize, err := databaseSize(moneroSync)
	if err != nil {
		return nil, err
	}
	health, err := health(member(moneroSync, "health", nil))
	if err != nil {
		return nil, err
	}
	mode, err := required(metrics, "monero_mode")
	if err != nil {
		return nil, err
	}
	return map[string]any{"mode": mode, "db_size": dbSize, "health": health}, nil
}

func databaseSize(sync map[string]any) (string, error) {
	value := member(sync, "db_size", json.Number("0"))
	if !truthy(value) {
		value = json.Number("0")
	}
	if _, ok := value.(string); ok {
		return "", fmt.Errorf("invalid database size")
	}
	n, err := number(value)
	if err != nil {
		return "", err
	}
	if n <= 0 {
		return "—", nil
	}
	return fmt.Sprintf("%.1f GB", n/1e9), nil
}

func health(value any) (map[string]any, error) {
	if !truthy(value) {
		value = map[string]any{}
	}
	item, err := object(value)
	if err != nil {
		return nil, err
	}
	level := member(item, "level", "unknown")
	if level == "unknown" && truthy(member(item, "syncing", nil)) {
		copy := make(map[string]any, len(item)+1)
		for key, raw := range item {
			copy[key] = raw
		}
		copy["reasons"] = []any{"Node is syncing — no at-tip verdict"}
		item = copy
	} else if level == "unknown" {
		status := "Peers not visible right now — no health verdict"
		if reachable, ok := item["reachable"]; ok && reachable == false {
			status = "Node not answering — see its down status"
		}
		return map[string]any{
			"level": "unknown", "status": status, "peers": "—", "moved": "—",
			"reasons": []any{}, "advice": "", "tooltip": healthTip,
		}, nil
	}
	reasons, err := stringList(member(item, "reasons", []any{}))
	if err != nil {
		return nil, err
	}
	status := "At tip, with peers"
	if len(reasons) != 0 {
		status = strings.Join(reasons, "; ")
	}
	peers := "—"
	if out := member(item, "peers_out", nil); out != nil {
		in := member(item, "peers_in", nil)
		inText := "—"
		if in != nil {
			inText = pythonString(in)
		}
		peers = pythonString(out) + " out / " + inText + " in"
	}
	moved := "—"
	if age := member(item, "advance_age_sec", nil); age != nil {
		formatted, err := duration(age)
		if err != nil {
			return nil, err
		}
		moved = formatted + " ago"
	}
	return map[string]any{
		"level": level, "status": status, "peers": peers, "moved": moved,
		"reasons": stringSliceAny(reasons), "advice": member(item, "advice", ""), "tooltip": healthTip,
	}, nil
}

func stringSliceAny(values []string) []any {
	result := make([]any, len(values))
	for index := range values {
		result[index] = values[index]
	}
	return result
}
