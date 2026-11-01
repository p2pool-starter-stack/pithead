package config

import (
	"encoding/json"
	"math"
	"sort"
	"strconv"
	"strings"
)

func objectField(root node, key string) (node, error) {
	if isNull(root) {
		return node{}, nil
	}
	if root.object == nil {
		return node{}, ErrUnsupportedValidation
	}
	value, _ := objectValue(root, key)
	return value, nil
}

func invalidFleetPort(value node) (bool, bool) {
	number, ok := value.value.(json.Number)
	if !ok {
		return true, false
	}
	raw := number.String()
	if !validJQInteger(raw) || raw == "-0" {
		return false, true
	}
	parsed, err := strconv.ParseInt(raw, 10, 64)
	return err != nil || parsed < 1 || parsed > 65535, false
}

func invalidIntegralPort(value node) (bool, bool) {
	number, ok := value.value.(json.Number)
	if !ok {
		return true, false
	}
	parsed, ok := validationFloat(number)
	if !ok {
		return false, true
	}
	return parsed != math.Floor(parsed) || parsed < 1 || parsed > 65535, false
}

func invalidWatts(value node) (bool, bool) {
	number, ok := value.value.(json.Number)
	if !ok {
		return true, false
	}
	parsed, ok := validationFloat(number)
	if !ok {
		return false, true
	}
	return parsed <= 0 || parsed >= 1000000, false
}

func invalidNonNegative(value node) (bool, bool) {
	number, ok := value.value.(json.Number)
	if !ok {
		return true, false
	}
	parsed, ok := validationFloat(number)
	if !ok {
		return false, true
	}
	return parsed < 0, false
}

func validationFloat(number json.Number) (float64, bool) {
	raw := number.String()
	mantissa := raw
	if index := strings.IndexAny(mantissa, "eE"); index >= 0 {
		exponent, err := strconv.Atoi(mantissa[index+1:])
		if err != nil || exponent < -308 || exponent > 308 {
			return 0, false
		}
		mantissa = mantissa[:index]
	}
	digits := 0
	started := false
	for _, current := range mantissa {
		if current < '0' || current > '9' {
			continue
		}
		if current != '0' {
			started = true
		}
		if started {
			digits++
		}
	}
	if digits > 15 {
		return 0, false
	}
	parsed, err := strconv.ParseFloat(raw, 64)
	return parsed, err == nil && !math.IsInf(parsed, 0) && !math.IsNaN(parsed) && !(parsed == 0 && started)
}

func printableASCII(value string, maximum int) bool {
	if len(value) == 0 || len(value) > maximum {
		return false
	}
	for _, current := range value {
		if current < '!' || current > '~' {
			return false
		}
	}
	return true
}

func validHost(value string) bool {
	if len(value) == 0 || len(value) > 253 {
		return false
	}
	for _, current := range value {
		if (current < 'A' || current > 'Z') && (current < 'a' || current > 'z') && (current < '0' || current > '9') && current != '.' && current != '_' && current != '-' {
			return false
		}
	}
	return true
}

func duplicateStrings(values []string) []string {
	counts := make(map[string]int, len(values))
	for _, value := range values {
		counts[value]++
	}
	result := make([]string, 0)
	for value, count := range counts {
		if count > 1 {
			result = append(result, value)
		}
	}
	sort.Strings(result)
	return result
}

func jqType(value node) string {
	switch {
	case value.object != nil:
		return "object"
	case value.array != nil:
		return "array"
	case isNull(value):
		return "null"
	}
	switch value.value.(type) {
	case string:
		return "string"
	case bool:
		return "boolean"
	case json.Number:
		return "number"
	default:
		return "null"
	}
}

func hasControlValue(value node) bool {
	if text, ok := value.value.(string); ok {
		for _, current := range text {
			if current <= 0x1f || current >= 0x7f && current <= 0x9f {
				return true
			}
		}
	}
	for _, item := range value.object {
		if hasControlValue(item.value) {
			return true
		}
	}
	for _, item := range value.array {
		if hasControlValue(item) {
			return true
		}
	}
	return false
}

func hasControlKey(value node) bool {
	for _, item := range value.object {
		for _, current := range item.key {
			if current <= 0x1f || current >= 0x7f && current <= 0x9f {
				return true
			}
		}
		if hasControlKey(item.value) {
			return true
		}
	}
	for _, item := range value.array {
		if hasControlKey(item) {
			return true
		}
	}
	return false
}
