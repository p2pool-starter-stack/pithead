package overview

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"math/big"
	"strconv"
	"strings"
	"time"
)

func arguments(raw []json.RawMessage, count int) ([]any, error) {
	if len(raw) != count {
		return nil, errors.New("invalid overview argument count")
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
			return nil, errors.New("invalid overview argument")
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

func array(value any) ([]any, error) {
	result, ok := value.([]any)
	if !ok {
		return nil, errors.New("expected array")
	}
	return result, nil
}

func member(values map[string]any, key string, fallback any) any {
	if value, ok := values[key]; ok {
		return value
	}
	return fallback
}

func required(values map[string]any, key string) (any, error) {
	value, ok := values[key]
	if !ok {
		return nil, errors.New("missing " + key)
	}
	return value, nil
}

func number(value any) (float64, error) {
	var result float64
	var err error
	switch value := value.(type) {
	case json.Number:
		result, err = value.Float64()
	case int:
		result = float64(value)
	case int64:
		result = float64(value)
	case float64:
		result = value
	case bool:
		if value {
			result = 1
		}
	default:
		err = errors.New("expected number")
	}
	if err != nil || math.IsNaN(result) || math.IsInf(result, 0) {
		return 0, errors.New("expected finite number")
	}
	return result, nil
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
		number, ok := new(big.Float).SetString(value.String())
		return ok && number.Sign() != 0
	case int:
		return value != 0
	case int64:
		return value != 0
	case float64:
		return value != 0
	case []any:
		return len(value) > 0
	case map[string]any:
		return len(value) > 0
	default:
		return true
	}
}

func pythonString(value any) string {
	switch value := value.(type) {
	case nil:
		return "None"
	case bool:
		if value {
			return "True"
		}
		return "False"
	case string:
		return value
	case json.Number:
		return value.String()
	default:
		return fmt.Sprint(value)
	}
}

func formatHashrate(value any) string {
	var n float64
	var err error
	switch value := value.(type) {
	case string:
		n, err = strconv.ParseFloat(strings.TrimSpace(value), 64)
	default:
		n, err = number(value)
	}
	if err != nil {
		return "0 H/s"
	}
	if math.IsNaN(n) {
		return "nan H/s"
	}
	if math.IsInf(n, 1) {
		return "inf GH/s"
	}
	if math.IsInf(n, -1) {
		return "-inf H/s"
	}
	switch {
	case n >= 1e9:
		return fmt.Sprintf("%.2f GH/s", n/1e9)
	case n >= 1e6:
		return fmt.Sprintf("%.2f MH/s", n/1e6)
	case n >= 1e3:
		return fmt.Sprintf("%.2f kH/s", n/1e3)
	default:
		return fmt.Sprintf("%.2f H/s", n)
	}
}

func formatDuration(value any) string {
	var seconds *big.Int
	switch value := value.(type) {
	case int:
		seconds = big.NewInt(int64(value))
	case int64:
		seconds = big.NewInt(value)
	case float64:
		if math.IsNaN(value) || math.IsInf(value, 0) {
			return "0s"
		}
		seconds, _ = new(big.Float).SetFloat64(value).Int(nil)
	case json.Number:
		if strings.ContainsAny(value.String(), ".eE") {
			n, err := value.Float64()
			if err != nil || math.IsNaN(n) || math.IsInf(n, 0) {
				return "0s"
			}
			seconds, _ = new(big.Float).SetFloat64(n).Int(nil)
		} else {
			seconds, _ = new(big.Int).SetString(value.String(), 10)
		}
	case string:
		seconds, _ = new(big.Int).SetString(strings.TrimSpace(value), 10)
	case bool:
		seconds = new(big.Int)
		if value {
			seconds.SetInt64(1)
		}
	}
	if seconds == nil {
		return "0s"
	}
	days := floorDiv(seconds, 86400)
	hours := floorMod(floorDiv(seconds, 3600), 24)
	minutes := floorMod(floorDiv(seconds, 60), 60)
	secs := floorMod(seconds, 60)
	if days.Sign() > 0 {
		return fmt.Sprintf("%sd %sh %sm", days, hours, minutes)
	}
	if hours.Sign() > 0 {
		return fmt.Sprintf("%sh %sm", hours, minutes)
	}
	return fmt.Sprintf("%sm %ss", minutes, secs)
}

func floorDiv(value *big.Int, divisor int64) *big.Int {
	quotient, remainder := new(big.Int), new(big.Int)
	quotient.QuoRem(value, big.NewInt(divisor), remainder)
	if remainder.Sign() < 0 {
		quotient.Sub(quotient, big.NewInt(1))
	}
	return quotient
}

func floorMod(value *big.Int, divisor int64) *big.Int {
	result := new(big.Int).Mod(value, big.NewInt(divisor))
	if result.Sign() < 0 {
		result.Add(result, big.NewInt(divisor))
	}
	return result
}

func formatTimeAbs(value any, location *time.Location) string {
	if !truthy(value) {
		return "Never"
	}
	timestamp, err := number(value)
	if err != nil || timestamp >= math.MaxInt64 || timestamp < math.MinInt64 {
		return "Invalid Time"
	}
	seconds, fraction := math.Modf(timestamp)
	return time.Unix(int64(seconds), int64(fraction*1e9)).In(location).Format("15:04:05")
}

func location(name string) (*time.Location, error) {
	if name == "" {
		return time.Local, nil
	}
	return time.LoadLocation(name)
}

func shortened(value string, keep, threshold int) string {
	runes := []rune(value)
	if len(runes) <= threshold {
		return value
	}
	return string(runes[:keep]) + "..." + string(runes[len(runes)-keep:])
}
