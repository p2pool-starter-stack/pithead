package infra

import (
	"encoding/json"
	"errors"
	"fmt"
	"math/big"
	"strings"
)

func buildProxySummary(raw []json.RawMessage) (any, error) {
	args, err := arguments(raw, 1)
	if err != nil {
		return nil, err
	}
	data, err := object(args[0])
	if err != nil {
		return nil, err
	}
	summaryValue := member(data, "proxy_summary", map[string]any{})
	if !truthy(summaryValue) {
		summaryValue = map[string]any{}
	}
	summary, err := object(summaryValue)
	if err != nil {
		return nil, err
	}
	values := make([]any, 5)
	for index, key := range []string{"accepted", "rejected", "invalid", "expired", "best"} {
		values[index] = member(summary, key, json.Number("0"))
		if !truthy(values[index]) {
			values[index] = json.Number("0")
		}
	}
	accepted, err := rational(values[0])
	if err != nil {
		return nil, err
	}
	rejected, err := rational(values[1])
	if err != nil {
		return nil, err
	}
	invalid, err := rational(values[2])
	if err != nil {
		return nil, err
	}
	total := new(big.Rat).Add(accepted, rejected)
	rejectPercent := 0.0
	if total.Sign() > 0 {
		ratio := new(big.Rat).Quo(rejected, total)
		rejectPercent, _ = ratio.Float64()
		rejectPercent *= 100
	}
	formatted := make([]string, 4)
	for index := range formatted {
		formatted[index], err = commaRaw(values[index])
		if err != nil {
			return nil, err
		}
	}
	best := "—"
	if truthy(values[4]) {
		best, err = commaInteger(values[4])
		if err != nil {
			return nil, err
		}
	}
	return map[string]any{
		"accepted": formatted[0], "rejected": formatted[1], "invalid": formatted[2],
		"expired": formatted[3], "best": best, "reject_pct": fmt.Sprintf("%.2f%%", rejectPercent),
		"reject_level": usageLevel(rejectPercent, 5), "has_data": new(big.Rat).Add(total, invalid).Sign() > 0,
	}, nil
}

func buildTari(raw []json.RawMessage) (any, error) {
	args, err := arguments(raw, 1)
	if err != nil {
		return nil, err
	}
	data, err := object(args[0])
	if err != nil {
		return nil, err
	}
	tari, err := objectMember(data, "tari")
	if err != nil {
		return nil, err
	}
	active := member(tari, "active", false)
	address := member(tari, "address", "Unknown")
	addressString, ok := address.(string)
	if !ok {
		return nil, errors.New("invalid Tari address")
	}
	healthContainer := member(data, "tari_sync", map[string]any{})
	if !truthy(healthContainer) {
		healthContainer = map[string]any{}
	}
	tariSync, err := object(healthContainer)
	if err != nil {
		return nil, err
	}
	health := member(tariSync, "health", nil)
	status := any("Waiting...")
	if truthy(active) {
		status = member(tari, "status", "Waiting...")
	}
	if truthy(health) {
		healthObject, err := object(health)
		if err != nil {
			return nil, err
		}
		if member(healthObject, "level", nil) != "green" {
			reasons, err := stringList(member(healthObject, "reasons", []any{}))
			if err != nil {
				return nil, err
			}
			status = fmt.Sprintf("Not following the chain: %s. %s", strings.Join(reasons, "; "), pythonString(member(healthObject, "advice", "")))
		}
	}
	reward, err := decimal(member(tari, "reward", json.Number("0")), 2)
	if err != nil {
		return nil, err
	}
	difficulty, err := commaInteger(member(tari, "difficulty", json.Number("0")))
	if err != nil {
		return nil, err
	}
	connected := any(false)
	if truthy(member(tari, "connected", false)) && truthy(active) {
		connected = active
	}
	return map[string]any{
		"active": active, "connected": connected, "status": status,
		"reward": reward + " TARI", "height": pythonString(member(tari, "height", json.Number("0"))),
		"diff": difficulty, "wallet": address, "wallet_short": shorten(addressString, 8, 16), "health": health,
	}, nil
}

func shorten(value string, keep, threshold int) string {
	runes := []rune(value)
	if len(runes) <= threshold {
		return value
	}
	return string(runes[:keep]) + "..." + string(runes[len(runes)-keep:])
}

func stringList(value any) ([]string, error) {
	if !truthy(value) {
		return []string{}, nil
	}
	items, ok := value.([]any)
	if !ok {
		return nil, errors.New("expected string list")
	}
	result := make([]string, len(items))
	for index, item := range items {
		result[index], ok = item.(string)
		if !ok {
			return nil, errors.New("expected string list")
		}
	}
	return result, nil
}
