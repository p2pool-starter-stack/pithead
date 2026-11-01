package charts

import (
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"strconv"
)

func number(value any) (float64, error) {
	return convertNumber(value, true)
}

func strictNumber(value any) (float64, error) {
	return convertNumber(value, false)
}

func convertNumber(value any, allowString bool) (float64, error) {
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
	case string:
		if !allowString {
			return 0, errors.New("not numeric")
		}
		result, err = strconv.ParseFloat(value, 64)
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

func pythonRound(value float64, places int) (float64, error) {
	text := fmt.Sprintf("%.*f", places, value)
	return strconv.ParseFloat(text, 64)
}

func formatHashrate(value any) string {
	n, err := number(value)
	if err != nil {
		return "0 H/s"
	}
	switch {
	case n >= 1_000_000_000:
		return fmt.Sprintf("%.2f GH/s", n/1_000_000_000)
	case n >= 1_000_000:
		return fmt.Sprintf("%.2f MH/s", n/1_000_000)
	case n >= 1_000:
		return fmt.Sprintf("%.2f kH/s", n/1_000)
	default:
		return fmt.Sprintf("%.2f H/s", n)
	}
}
