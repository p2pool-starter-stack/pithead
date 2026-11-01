package series

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"math"
	"strconv"
)

func decode(raw json.RawMessage, target any) error {
	if len(raw) == 0 {
		return errors.New("missing argument")
	}
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.UseNumber()
	if err := decoder.Decode(target); err != nil {
		return err
	}
	var trailing any
	if err := decoder.Decode(&trailing); !errors.Is(err, io.EOF) {
		if err == nil {
			return errors.New("multiple argument values")
		}
		return err
	}
	return nil
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
	case bool:
		if value {
			return 1, true
		}
		return 0, true
	}
	return 0, false
}

func truthy(value any) bool {
	switch value := value.(type) {
	case nil:
		return false
	case bool:
		return value
	case string:
		return value != ""
	case []any:
		return len(value) != 0
	case map[string]any:
		return len(value) != 0
	default:
		value, err := number(value)
		return err != nil || value != 0
	}
}

func rawOrZero(row map[string]any, key string) any {
	value, ok := row[key]
	if !ok || !truthy(value) {
		return 0
	}
	return value
}

func rawDefault(row map[string]any, key string) any {
	value, ok := row[key]
	if !ok {
		return 0
	}
	return value
}
