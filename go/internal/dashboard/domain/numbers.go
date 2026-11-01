package domain

import (
	"bytes"
	"encoding/json"
	"errors"
	"math"
	"strconv"
	"strings"
)

type PythonFloat float64

func (value PythonFloat) MarshalJSON() ([]byte, error) {
	encoded, err := json.Marshal(float64(value))
	if err != nil {
		return nil, err
	}
	if !bytes.ContainsAny(encoded, ".eE") {
		encoded = append(encoded, '.', '0')
	}
	return encoded, nil
}

func number(value any) (float64, error) {
	var result float64
	var err error
	switch value := value.(type) {
	case json.Number:
		result, err = value.Float64()
	case float64:
		result = value
	case float32:
		result = float64(value)
	case int:
		result = float64(value)
	case int64:
		result = float64(value)
	case int32:
		result = float64(value)
	case uint:
		result = float64(value)
	case uint64:
		result = float64(value)
	case uint32:
		result = float64(value)
	case bool:
		if value {
			result = 1
		}
	default:
		return 0, errors.New("not numeric")
	}
	if err != nil || math.IsNaN(result) || math.IsInf(result, 0) {
		return 0, errors.New("not finite")
	}
	return result, nil
}

func integer(value any) (int64, bool) {
	switch value := value.(type) {
	case json.Number:
		result, err := strconv.ParseInt(value.String(), 10, 64)
		return result, err == nil
	case int:
		return int64(value), true
	case int64:
		return value, true
	case int32:
		return int64(value), true
	case uint:
		if uint64(value) <= math.MaxInt64 {
			return int64(value), true
		}
	case uint64:
		if value <= math.MaxInt64 {
			return int64(value), true
		}
	case uint32:
		return int64(value), true
	case bool:
		if value {
			return 1, true
		}
		return 0, true
	}
	return 0, false
}

func subtract(left, right any) (any, error) {
	if integerOverflow(left) || integerOverflow(right) {
		return nil, errors.New("integer overflow")
	}
	leftInt, leftOK := integer(left)
	rightInt, rightOK := integer(right)
	if leftOK && rightOK {
		if rightInt > 0 && leftInt < math.MinInt64+rightInt || rightInt < 0 && leftInt > math.MaxInt64+rightInt {
			return nil, errors.New("integer overflow")
		}
		return leftInt - rightInt, nil
	}
	a, err := number(left)
	if err != nil {
		return nil, err
	}
	b, err := number(right)
	if err != nil {
		return nil, err
	}
	return PythonFloat(a - b), nil
}

func integerOverflow(value any) bool {
	switch value := value.(type) {
	case json.Number:
		text := value.String()
		if strings.ContainsAny(text, ".eE") {
			return false
		}
		_, err := strconv.ParseInt(text, 10, 64)
		return err != nil
	case uint:
		return uint64(value) > math.MaxInt64
	case uint64:
		return value > math.MaxInt64
	}
	return false
}

func addInteger(left, right int64) (int64, error) {
	if right > 0 && left > math.MaxInt64-right || right < 0 && left < math.MinInt64-right {
		return 0, errors.New("integer overflow")
	}
	return left + right, nil
}

func truthy(value any) bool {
	switch value := value.(type) {
	case nil:
		return false
	case bool:
		return value
	case string:
		return value != ""
	case json.Number:
		n, err := value.Float64()
		return err == nil && n != 0
	case float64:
		return value != 0
	case float32:
		return value != 0
	case int:
		return value != 0
	case int64:
		return value != 0
	case int32:
		return value != 0
	case []any:
		return len(value) != 0
	case map[string]any:
		return len(value) != 0
	default:
		return true
	}
}

func rawOrZero(values map[string]any, key string) any {
	value, ok := values[key]
	if !ok || !truthy(value) {
		return 0
	}
	return value
}

func object(values map[string]any, key string) (map[string]any, error) {
	value, ok := values[key]
	if !ok {
		return map[string]any{}, nil
	}
	result, ok := value.(map[string]any)
	if !ok {
		return nil, errors.New("not an object")
	}
	return result, nil
}

func rows(values map[string]any, key string) ([]any, error) {
	value, ok := values[key]
	if !ok {
		return []any{}, nil
	}
	result, ok := value.([]any)
	if !ok {
		return nil, errors.New("not an array")
	}
	return result, nil
}
