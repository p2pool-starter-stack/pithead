package fleet

import (
	"errors"
	"math"
)

func detailArguments(request Request, count int) ([]any, error) {
	values, err := arguments(request.Args, count)
	if err != nil || request.NonfiniteMarker == "" {
		return values, err
	}
	for index, value := range values {
		values[index], err = unpackDetailValue(value, request.NonfiniteMarker)
		if err != nil {
			return nil, err
		}
	}
	return values, nil
}

func unpackDetailValue(value any, marker string) (any, error) {
	switch value := value.(type) {
	case map[string]any:
		if special, ok := value[marker]; ok && len(value) == 1 {
			switch special {
			case "inf":
				return math.Inf(1), nil
			case "-inf":
				return math.Inf(-1), nil
			case "nan":
				return math.NaN(), nil
			default:
				return nil, errors.New("invalid nonfinite marker")
			}
		}
		for key, item := range value {
			decoded, err := unpackDetailValue(item, marker)
			if err != nil {
				return nil, err
			}
			value[key] = decoded
		}
	case []any:
		for index, item := range value {
			decoded, err := unpackDetailValue(item, marker)
			if err != nil {
				return nil, err
			}
			value[index] = decoded
		}
	}
	return value, nil
}

func packDetailValue(value any, marker string) any {
	switch value := value.(type) {
	case float64:
		if math.IsNaN(value) {
			return map[string]any{marker: "nan"}
		}
		if math.IsInf(value, 1) {
			return map[string]any{marker: "inf"}
		}
		if math.IsInf(value, -1) {
			return map[string]any{marker: "-inf"}
		}
	case map[string]any:
		for key, item := range value {
			value[key] = packDetailValue(item, marker)
		}
	case []any:
		for index, item := range value {
			value[index] = packDetailValue(item, marker)
		}
	}
	return value
}
