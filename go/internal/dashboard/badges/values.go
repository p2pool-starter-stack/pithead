package badges

import (
	"encoding/json"
	"errors"
	"io"
	"math"
	"math/big"
	"strconv"
	"strings"
)

func arguments(raw []json.RawMessage, count int) ([]any, error) {
	if len(raw) != count {
		return nil, errors.New("invalid badges argument count")
	}
	values := make([]any, count)
	for index := range raw {
		decoder := json.NewDecoder(strings.NewReader(string(raw[index])))
		decoder.UseNumber()
		if err := decoder.Decode(&values[index]); err != nil {
			return nil, err
		}
		var trailing any
		if err := decoder.Decode(&trailing); !errors.Is(err, io.EOF) {
			return nil, errors.New("invalid badges argument")
		}
	}
	return values, nil
}

func object(value any) (map[string]any, error) {
	result, ok := value.(map[string]any)
	if !ok {
		return nil, errors.New("expected object")
	}
	return result, nil
}

func member(value map[string]any, key string, fallback any) any {
	if found, ok := value[key]; ok {
		return found
	}
	return fallback
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
		number, ok := new(big.Rat).SetString(value.String())
		return ok && number.Sign() != 0
	case []any:
		return len(value) != 0
	case map[string]any:
		return len(value) != 0
	default:
		return true
	}
}

func number(value any) (float64, error) {
	switch value := value.(type) {
	case json.Number:
		result, err := value.Float64()
		if err == nil && !math.IsNaN(result) && !math.IsInf(result, 0) {
			return result, nil
		}
	case bool:
		if value {
			return 1, nil
		}
		return 0, nil
	}
	return 0, errors.New("expected finite number")
}

func requiredString(value map[string]any, key string) (string, error) {
	result, ok := value[key].(string)
	if !ok {
		return "", errors.New("expected string " + key)
	}
	return result, nil
}

func requiredBool(value map[string]any, key string) (bool, error) {
	result, ok := value[key].(bool)
	if !ok {
		return false, errors.New("expected bool " + key)
	}
	return result, nil
}

func requiredNumber(value map[string]any, key string) (float64, error) {
	found, ok := value[key]
	if !ok {
		return 0, errors.New("missing " + key)
	}
	return number(found)
}

func pythonString(value any) (string, error) {
	switch value := value.(type) {
	case string:
		return value, nil
	case json.Number:
		return value.String(), nil
	case bool:
		if value {
			return "True", nil
		}
		return "False", nil
	case nil:
		return "None", nil
	default:
		return "", errors.New("unsupported string value")
	}
}

func general(value float64) string {
	if value == 0 {
		return "0"
	}
	return strconv.FormatFloat(value, 'g', 6, 64)
}

func fixed(value float64, places int) string {
	return strconv.FormatFloat(value, 'f', places, 64)
}
