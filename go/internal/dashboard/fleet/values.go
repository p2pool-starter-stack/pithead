package fleet

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"math/big"
	"strconv"
	"strings"
)

func arguments(raw []json.RawMessage, count int) ([]any, error) {
	if len(raw) != count {
		return nil, errors.New("invalid fleet argument count")
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
			return nil, errors.New("invalid fleet argument")
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

func member(value map[string]any, key string, fallback any) any {
	if found, ok := value[key]; ok {
		return found
	}
	return fallback
}

func required(value map[string]any, key string) (any, error) {
	found, ok := value[key]
	if !ok {
		return nil, errors.New("missing " + key)
	}
	return found, nil
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
		n, ok := new(big.Rat).SetString(value.String())
		return ok && n.Sign() != 0
	case []any:
		return len(value) != 0
	case map[string]any:
		return len(value) != 0
	default:
		return true
	}
}

func numeric(value any) (float64, bool) {
	n, ok := value.(json.Number)
	if !ok {
		return 0, false
	}
	result, err := n.Float64()
	return result, err == nil && !math.IsNaN(result) && !math.IsInf(result, 0)
}

func integerNumber(value any) (*big.Int, bool) {
	number, ok := value.(json.Number)
	if !ok || strings.ContainsAny(number.String(), ".eE") {
		return nil, false
	}
	result, ok := new(big.Int).SetString(number.String(), 10)
	return result, ok
}

func integerValue(value any) (*big.Int, bool) {
	if result, ok := integerNumber(value); ok {
		return result, true
	}
	switch value := value.(type) {
	case json.Number:
		number, err := value.Float64()
		if err != nil || math.IsInf(number, 0) || math.IsNaN(number) {
			return nil, false
		}
		result, _ := new(big.Float).SetFloat64(number).Int(nil)
		return result, true
	case string:
		result, ok := new(big.Int).SetString(strings.TrimSpace(value), 10)
		return result, ok
	case bool:
		if value {
			return big.NewInt(1), true
		}
		return new(big.Int), true
	default:
		return nil, false
	}
}

func pythonRound(value float64, places int) float64 {
	rounded, err := strconv.ParseFloat(strconv.FormatFloat(value, 'f', places, 64), 64)
	if err != nil {
		return value
	}
	return rounded
}

func fmtNumber(value float64) string {
	if value == 0 {
		return "0"
	}
	if value == math.Trunc(value) {
		return strconv.FormatFloat(value, 'f', 0, 64)
	}
	return strconv.FormatFloat(value, 'g', -1, 64)
}

func fmtNumeric(value any) (string, error) {
	if integer, ok := integerNumber(value); ok {
		return integer.String(), nil
	}
	number, ok := numeric(value)
	if !ok {
		return "", errors.New("expected numeric value")
	}
	return fmtNumber(number), nil
}

func roundedNumeric(value any, places int) (string, error) {
	if integer, ok := integerNumber(value); ok {
		return integer.String(), nil
	}
	number, ok := numeric(value)
	if !ok {
		return "", errors.New("expected numeric value")
	}
	return fmtNumber(pythonRound(number, places)), nil
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
	case json.Number:
		return value.String()
	case string:
		return value
	default:
		return fmt.Sprint(value)
	}
}

func formatDuration(value any) string {
	seconds, ok := integerValue(value)
	if !ok {
		return "0s"
	}
	days := new(big.Int).Div(new(big.Int).Set(seconds), big.NewInt(86400))
	hours := new(big.Int).Mod(new(big.Int).Div(new(big.Int).Set(seconds), big.NewInt(3600)), big.NewInt(24))
	minutes := new(big.Int).Mod(new(big.Int).Div(new(big.Int).Set(seconds), big.NewInt(60)), big.NewInt(60))
	secs := new(big.Int).Mod(new(big.Int).Set(seconds), big.NewInt(60))
	if days.Sign() > 0 {
		return fmt.Sprintf("%sd %sh %sm", days, hours, minutes)
	}
	if hours.Sign() > 0 {
		return fmt.Sprintf("%sh %sm", hours, minutes)
	}
	return fmt.Sprintf("%sm %ss", minutes, secs)
}

func formatHashrate(value any) string {
	var n float64
	var err error
	switch value := value.(type) {
	case json.Number:
		n, err = value.Float64()
	case string:
		n, err = strconv.ParseFloat(value, 64)
	case bool:
		if value {
			n = 1
		}
	default:
		err = errors.New("not numeric")
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

func comma(value any) (string, error) {
	n, ok := value.(json.Number)
	if !ok {
		return "", errors.New("expected number")
	}
	text := n.String()
	if strings.ContainsAny(text, ".eE") {
		value, err := n.Float64()
		if err != nil || math.IsNaN(value) || math.IsInf(value, 0) {
			return "", errors.New("invalid float")
		}
		return commaFloat(value), nil
	}
	integer, ok := integerNumber(n)
	if !ok {
		return "", errors.New("invalid integer")
	}
	return groupDecimal(integer.String()), nil
}

func commaFloat(value float64) string {
	absolute := math.Abs(value)
	if absolute != 0 && (absolute < 1e-4 || absolute >= 1e16) {
		return strconv.FormatFloat(value, 'g', -1, 64)
	}
	text := strconv.FormatFloat(value, 'f', -1, 64)
	if !strings.Contains(text, ".") {
		text += ".0"
	}
	parts := strings.SplitN(text, ".", 2)
	return groupDecimal(parts[0]) + "." + parts[1]
}

func groupDecimal(text string) string {
	parts := strings.SplitN(text, ".", 2)
	integer := parts[0]
	sign := ""
	if strings.HasPrefix(integer, "-") {
		sign, integer = "-", integer[1:]
	}
	first := len(integer) % 3
	if first == 0 {
		first = 3
	}
	var out strings.Builder
	out.WriteString(sign)
	out.WriteString(integer[:first])
	for index := first; index < len(integer); index += 3 {
		out.WriteByte(',')
		out.WriteString(integer[index : index+3])
	}
	if len(parts) == 2 {
		out.WriteByte('.')
		out.WriteString(parts[1])
	}
	return out.String()
}
