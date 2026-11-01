package fleet

import (
	"encoding/json"
	"errors"
	"fmt"
	"math/big"
	"sort"
	"strings"
)

func buildWorkers(raw []json.RawMessage, now float64) (any, error) {
	values, err := arguments(raw, 2)
	if err != nil {
		return nil, err
	}
	workers, err := array(values[0])
	if err != nil {
		return nil, err
	}
	var release map[string]any
	if truthy(values[1]) {
		release, err = object(values[1])
		if err != nil {
			return nil, err
		}
	}
	type sortableWorker struct {
		value  map[string]any
		name   string
		online bool
	}
	sorted := make([]sortableWorker, 0, len(workers))
	for _, value := range workers {
		worker, err := object(value)
		if err != nil {
			return nil, err
		}
		name, nameOK := worker["name"].(string)
		status, statusOK := worker["status"].(string)
		if !nameOK || !statusOK {
			return nil, errors.New("worker missing sortable fields")
		}
		sorted = append(sorted, sortableWorker{worker, name, status == "online"})
	}
	sort.SliceStable(sorted, func(i, j int) bool {
		if sorted[i].online != sorted[j].online {
			return sorted[i].online
		}
		return sorted[i].name < sorted[j].name
	})
	rows := make([]any, 0, len(sorted))
	for _, item := range sorted {
		worker := item.value
		ip, ok := worker["ip"].(string)
		if !ok {
			continue
		}
		activePool, ok := member(worker, "active_pool", "").(string)
		if !ok {
			continue
		}
		pool := "unknown"
		if containsAny(activePool, "3333", "37889", "37888", "37890") {
			pool = "p2pool"
		} else if containsAny(activePool, "3344", "4247") {
			pool = "xvb"
		}
		uptime := member(worker, "uptime", json.Number("0"))
		h60 := member(worker, "h60", json.Number("0"))
		h15 := member(worker, "h15", json.Number("0"))
		accepted := member(worker, "accepted", json.Number("0"))
		rejected := member(worker, "rejected", json.Number("0"))
		invalid := member(worker, "invalid", json.Number("0"))
		acceptedString, err := comma(accepted)
		if err != nil {
			continue
		}
		rejectedString, err := comma(rejected)
		if err != nil {
			continue
		}
		if truthy(invalid) {
			invalidString, err := comma(invalid)
			if err != nil {
				continue
			}
			rejectedString += " (+" + invalidString + " inv)"
		}
		rejectFlag, err := rejectFlag(accepted, rejected)
		if err != nil {
			continue
		}
		var display any
		if truthy(member(worker, "rigforge", nil)) {
			rf, err := object(worker["rigforge"])
			if err != nil {
				continue
			}
			display, err = rigforgeDisplay(rf, item.online, now)
			if err != nil {
				continue
			}
		}
		update, err := rigforgeUpdate(worker, release, now)
		if err != nil {
			continue
		}
		rows = append(rows, map[string]any{
			"name": item.name, "ip": ip, "ip_sort": ipSort(ip), "pool": pool,
			"status": map[bool]string{true: "online", false: "offline"}[item.online],
			"uptime": uptime, "uptime_str": formatDuration(uptime),
			"h60": h60, "h60_str": formatHashrate(h60), "h15": h15, "h15_str": formatHashrate(h15),
			"accepted": accepted, "accepted_str": acceptedString, "rejected": rejected,
			"rejected_str": rejectedString, "invalid": invalid, "reject_flag": rejectFlag,
			"api_ok": member(worker, "api_ok", nil), "adopted": member(worker, "adopted", nil),
			"rigforge": display, "rigforge_update": update,
		})
	}
	return rows, nil
}

func buildRigforgeUpdate(raw []json.RawMessage, now float64) (any, error) {
	values, err := arguments(raw, 2)
	if err != nil {
		return nil, err
	}
	if !truthy(values[0]) || !truthy(values[1]) {
		return nil, nil
	}
	worker, err := object(values[0])
	if err != nil {
		return nil, err
	}
	release, err := object(values[1])
	if err != nil {
		return nil, err
	}
	return rigforgeUpdate(worker, release, now)
}

func rigforgeUpdate(worker, release map[string]any, now float64) (any, error) {
	if len(release) == 0 || !truthy(member(worker, "rigforge", nil)) {
		return nil, nil
	}
	rf, err := object(worker["rigforge"])
	if err != nil {
		return nil, err
	}
	if _, fresh := feedAge(member(rf, "generated_at", nil), now); !fresh {
		return nil, nil
	} else if age, _ := feedAge(member(rf, "generated_at", nil), now); age > 60 {
		return nil, nil
	}
	version, ok := member(rf, "version", nil).(string)
	if !ok || version == "" {
		return nil, nil
	}
	tag, ok := member(release, "tag", nil).(string)
	if !ok {
		return nil, nil
	}
	running, runningOK := semver(version)
	latest, latestOK := semver(tag)
	if !runningOK || !latestOK || compareSemver(latest, running) <= 0 {
		return nil, nil
	}
	return map[string]any{"available": true, "latest": tag, "url": member(release, "url", nil)}, nil
}

func semver(value string) ([3]*big.Int, bool) {
	var result [3]*big.Int
	core := strings.TrimSpace(value)
	core = strings.TrimLeft(core, "vV")
	core = strings.SplitN(core, "-", 2)[0]
	core = strings.SplitN(core, "+", 2)[0]
	parts := strings.Split(core, ".")
	if len(parts) < 3 {
		return result, false
	}
	for index := range result {
		if parts[index] == "" || strings.Trim(parts[index], "0123456789") != "" {
			return result, false
		}
		result[index], _ = new(big.Int).SetString(parts[index], 10)
	}
	return result, true
}

func compareSemver(left, right [3]*big.Int) int {
	for index := range left {
		if comparison := left[index].Cmp(right[index]); comparison != 0 {
			return comparison
		}
	}
	return 0
}

func buildRejectFlag(raw []json.RawMessage) (any, error) {
	values, err := arguments(raw, 2)
	if err != nil {
		return nil, err
	}
	return rejectFlag(values[0], values[1])
}

func rejectFlag(accepted, rejected any) (any, error) {
	var rate float64
	acceptedInteger, acceptedIsInteger := integerNumber(accepted)
	rejectedInteger, rejectedIsInteger := integerNumber(rejected)
	if acceptedIsInteger && rejectedIsInteger {
		total := new(big.Int).Add(new(big.Int).Set(acceptedInteger), rejectedInteger)
		if total.Sign() <= 0 || rejectedInteger.Cmp(big.NewInt(3)) < 0 {
			return nil, nil
		}
		rate, _ = new(big.Rat).SetFrac(rejectedInteger, total).Float64()
	} else {
		a, aOK := numeric(accepted)
		r, rOK := numeric(rejected)
		if !aOK || !rOK {
			return nil, errors.New("expected share counts")
		}
		total := a + r
		if total <= 0 || r < 3 {
			return nil, nil
		}
		rate = r / total
	}
	if rate < .05 {
		return nil, nil
	}
	return map[string]any{"text": "⚠", "title": fmt.Sprintf("High reject rate: %.1f%% (%s rejected)", rate*100, pythonString(rejected))}, nil
}

func buildIPSort(raw []json.RawMessage) (any, error) {
	values, err := arguments(raw, 1)
	if err != nil {
		return nil, err
	}
	ip, ok := values[0].(string)
	if !ok {
		return json.Number("0"), nil
	}
	return ipSort(ip), nil
}

func ipSort(ip string) any {
	parts := strings.Split(ip, ".")
	if len(parts) != 4 {
		return json.Number("0")
	}
	result := new(big.Int)
	for index, part := range parts {
		value, ok := new(big.Int).SetString(strings.TrimSpace(part), 10)
		if !ok {
			return json.Number("0")
		}
		value.Lsh(value, uint(8*(3-index)))
		result.Add(result, value)
	}
	return json.Number(result.String())
}

func containsAny(value string, options ...string) bool {
	for _, option := range options {
		if strings.Contains(value, option) {
			return true
		}
	}
	return false
}
