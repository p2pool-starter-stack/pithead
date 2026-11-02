package fleet

import (
	"errors"
	"math"
	"math/big"
)

func validateDriftBounds(last, rig any, unsettled bool) error {
	left, leftOK := last.(map[string]any)
	right, rightOK := rig.(map[string]any)
	if unsettled || !leftOK || !rightOK {
		return nil
	}
	left = stripCredentials(left, 0).(map[string]any)
	right = stripCredentials(right, 0).(map[string]any)
	for key, applied := range left {
		if observed, ok := right[key]; ok && (containsDriftNaN(applied) || containsDriftNaN(observed)) {
			return errors.New("NaN config comparison requires Python object identity")
		}
	}
	for key := range canonicalNumber {
		applied, appliedOK := left[key]
		observed, observedOK := right[key]
		if !appliedOK || !observedOK {
			continue
		}
		for _, value := range []any{applied, observed} {
			if integer, ok := integerNumber(value); ok {
				number, _ := new(big.Float).SetInt(integer).Float64()
				if math.IsInf(number, 0) {
					return errors.New("worker config integer exceeds float range")
				}
			}
		}
	}
	return nil
}

func containsDriftNaN(value any) bool {
	switch value := value.(type) {
	case float64:
		return math.IsNaN(value)
	case map[string]any:
		for _, item := range value {
			if containsDriftNaN(item) {
				return true
			}
		}
	case []any:
		for _, item := range value {
			if containsDriftNaN(item) {
				return true
			}
		}
	}
	return false
}

func formatDetailHashrate(value any) (string, error) {
	if integer, ok := integerNumber(value); ok {
		number, _ := new(big.Float).SetInt(integer).Float64()
		if math.IsInf(number, 0) {
			return "", errors.New("worker hashrate integer exceeds float range")
		}
	}
	return formatHashrate(value), nil
}
