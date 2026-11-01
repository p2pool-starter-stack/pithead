package resources

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"math"
	"math/big"
	"strings"
)

type numeric struct {
	float   float64
	integer *big.Int
}

func decode(raw json.RawMessage) (any, error) {
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.UseNumber()
	var value any
	if err := decoder.Decode(&value); err != nil {
		return nil, err
	}
	var trailing any
	if err := decoder.Decode(&trailing); !errors.Is(err, io.EOF) {
		if err == nil {
			return nil, errors.New("multiple argument values")
		}
		return nil, err
	}
	return value, nil
}

func number(value any) (float64, bool) {
	n, ok := parseNumeric(value)
	return n.float, ok
}

func parseNumeric(value any) (numeric, bool) {
	raw, ok := value.(json.Number)
	if !ok {
		return numeric{}, false
	}
	f, err := raw.Float64()
	if err != nil || math.IsNaN(f) || math.IsInf(f, 0) {
		return numeric{}, false
	}
	result := numeric{float: f}
	if !strings.ContainsAny(raw.String(), ".eE") {
		result.integer = new(big.Int)
		if _, ok := result.integer.SetString(raw.String(), 10); !ok {
			return numeric{}, false
		}
	}
	return result, true
}

func nonnegative(value numeric) bool {
	if value.integer != nil {
		return value.integer.Sign() >= 0
	}
	return value.float >= 0
}

func greater(left, right numeric) bool {
	if left.integer != nil && right.integer != nil {
		return left.integer.Cmp(right.integer) > 0
	}
	return left.float > right.float
}

func zero(value numeric) bool {
	if value.integer != nil {
		return value.integer.Sign() == 0
	}
	return value.float == 0
}

func sumEquals(left, right, total numeric) bool {
	if left.integer != nil && right.integer != nil && total.integer != nil {
		return new(big.Int).Add(left.integer, right.integer).Cmp(total.integer) == 0
	}
	return left.float+right.float == total.float
}

var maxExactInteger = big.NewInt(1<<53 - 1)

func capacityNumber(value any) (float64, bool, error) {
	n, ok := parseNumeric(value)
	if !ok {
		return 0, false, nil
	}
	if n.integer != nil && new(big.Int).Abs(n.integer).Cmp(maxExactInteger) > 0 {
		return 0, false, errors.New("capacity integer exceeds exact range")
	}
	return n.float, true, nil
}

func truthy(value any) bool {
	switch value := value.(type) {
	case nil:
		return false
	case bool:
		return value
	case json.Number:
		f, ok := number(value)
		return !ok || f != 0
	case string:
		return value != ""
	case []any:
		return len(value) != 0
	case map[string]any:
		return len(value) != 0
	default:
		return true
	}
}

func mapValue(value any) map[string]any {
	result, _ := value.(map[string]any)
	return result
}
