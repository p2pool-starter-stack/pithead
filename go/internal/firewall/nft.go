package firewall

import (
	"encoding/json"
	"errors"
	"io"
	"math"
	"math/big"
	"regexp"
	"strings"
)

const maxSafeJSONInteger = 1 << 53

func validateNFT(value string, ports []string) (bool, error) {
	decoder := json.NewDecoder(strings.NewReader(value))
	decoder.UseNumber()
	var document map[string]any
	if err := decoder.Decode(&document); err != nil {
		return false, ErrUnsupportedInput
	}
	if err := decoder.Decode(&struct{}{}); !errors.Is(err, io.EOF) {
		return false, ErrUnsupportedInput
	}
	items, ok := document["nftables"].([]any)
	if !ok {
		return false, ErrUnsupportedInput
	}
	hooks := make(map[string]bool)
	for _, item := range items {
		entry, ok := item.(map[string]any)
		if !ok {
			return false, ErrUnsupportedInput
		}
		chainValue, exists := entry["chain"]
		if !exists {
			continue
		}
		chain, ok := chainValue.(map[string]any)
		if !ok {
			return false, ErrUnsupportedInput
		}
		if chain["hook"] == "forward" {
			name, ok := chain["name"].(string)
			if !ok {
				return false, ErrUnsupportedInput
			}
			hooks[name] = true
		}
	}
	matched := false
	for _, item := range items {
		entry := item.(map[string]any)
		ruleValue, exists := entry["rule"]
		if !exists {
			continue
		}
		rule, ok := ruleValue.(map[string]any)
		if !ok {
			return false, ErrUnsupportedInput
		}
		chain, ok := rule["chain"].(string)
		if !ok {
			return false, ErrUnsupportedInput
		}
		if !hooks[chain] {
			continue
		}
		expr, ok := rule["expr"].([]any)
		if !ok {
			return false, ErrUnsupportedInput
		}
		drop := false
		for _, part := range expr {
			object, ok := part.(map[string]any)
			if !ok {
				return false, ErrUnsupportedInput
			}
			if _, ok := object["drop"]; ok {
				drop = true
			}
		}
		if !drop {
			continue
		}
		normalized, err := normalizeJSONNumbers(expr)
		if err != nil {
			return false, err
		}
		encoded, err := json.Marshal(normalized)
		if err != nil {
			return false, ErrUnsupportedInput
		}
		if containsPorts(string(encoded), ports) {
			matched = true
		}
	}
	return matched, nil
}

func normalizeJSONNumbers(value any) (any, error) {
	switch value := value.(type) {
	case json.Number:
		if len(value) > 512 {
			return nil, ErrUnsupportedInput
		}
		number, err := value.Float64()
		if err != nil || math.IsInf(number, 0) || math.Trunc(number) != number || math.Abs(number) > maxSafeJSONInteger || (number == 0 && strings.ContainsAny(string(value), "eE")) {
			return nil, ErrUnsupportedInput
		}
		exact, ok := new(big.Rat).SetString(string(value))
		if !ok || !exact.IsInt() || new(big.Rat).Abs(exact).Cmp(big.NewRat(maxSafeJSONInteger, 1)) > 0 {
			return nil, ErrUnsupportedInput
		}
		return number, nil
	case string:
		if strings.ContainsAny(value, "\u2028\u2029") {
			return nil, ErrUnsupportedInput
		}
		return value, nil
	case []any:
		result := make([]any, len(value))
		for index, item := range value {
			normalized, err := normalizeJSONNumbers(item)
			if err != nil {
				return nil, err
			}
			result[index] = normalized
		}
		return result, nil
	case map[string]any:
		result := make(map[string]any, len(value))
		for key, item := range value {
			if strings.ContainsAny(key, "\u2028\u2029") {
				return nil, ErrUnsupportedInput
			}
			normalized, err := normalizeJSONNumbers(item)
			if err != nil {
				return nil, err
			}
			result[key] = normalized
		}
		return result, nil
	default:
		return value, nil
	}
}

func containsPorts(value string, ports []string) bool {
	for _, port := range ports {
		if !regexp.MustCompile(`[^0-9]` + port + `[^0-9]`).MatchString(value) {
			return false
		}
	}
	return true
}
