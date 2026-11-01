package infra

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
		return nil, errors.New("invalid infrastructure argument count")
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
			return nil, errors.New("invalid infrastructure argument")
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

func required(value map[string]any, key string) (any, error) {
	found, ok := value[key]
	if !ok {
		return nil, errors.New("missing " + key)
	}
	return found, nil
}

func objectMember(value map[string]any, key string) (map[string]any, error) {
	found := member(value, key, map[string]any{})
	return object(found)
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
		if err == nil && !math.IsInf(result, 0) && !math.IsNaN(result) {
			return result, nil
		}
	case string:
		result, err := strconv.ParseFloat(value, 64)
		if err == nil && !math.IsInf(result, 0) && !math.IsNaN(result) {
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

func rational(value any) (*big.Rat, error) {
	switch value := value.(type) {
	case json.Number:
		if result, ok := new(big.Rat).SetString(value.String()); ok {
			return result, nil
		}
	case bool:
		if value {
			return big.NewRat(1, 1), nil
		}
		return new(big.Rat), nil
	}
	return nil, errors.New("expected finite number")
}

func integer(value any) (*big.Int, error) {
	switch value := value.(type) {
	case json.Number:
		text := value.String()
		if !strings.ContainsAny(text, ".eE") {
			if result, ok := new(big.Int).SetString(text, 10); ok {
				return result, nil
			}
		}
		n, err := value.Float64()
		if err == nil && !math.IsInf(n, 0) && !math.IsNaN(n) {
			result, _ := new(big.Float).SetFloat64(math.Trunc(n)).Int(nil)
			return result, nil
		}
	case string:
		if result, ok := new(big.Int).SetString(strings.TrimSpace(value), 10); ok {
			return result, nil
		}
	case bool:
		if value {
			return big.NewInt(1), nil
		}
		return big.NewInt(0), nil
	}
	return nil, errors.New("expected integer-compatible value")
}

func decimal(value any, places int) (string, error) {
	if _, ok := value.(string); ok {
		return "", errors.New("expected numeric format value")
	}
	if raw, ok := value.(json.Number); ok && !strings.ContainsAny(raw.String(), ".eE") {
		return raw.String() + "." + strings.Repeat("0", places), nil
	}
	n, err := number(value)
	if err != nil {
		return "", err
	}
	return strconv.FormatFloat(n, 'f', places, 64), nil
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

func commaInteger(value any) (string, error) {
	n, err := integer(value)
	if err != nil {
		return "", err
	}
	text := n.String()
	sign := ""
	if strings.HasPrefix(text, "-") {
		sign, text = "-", text[1:]
	}
	first := len(text) % 3
	if first == 0 {
		first = 3
	}
	var result strings.Builder
	result.WriteString(sign)
	result.WriteString(text[:first])
	for index := first; index < len(text); index += 3 {
		result.WriteByte(',')
		result.WriteString(text[index : index+3])
	}
	return result.String(), nil
}

func commaRaw(value any) (string, error) {
	if raw, ok := value.(json.Number); ok && strings.ContainsAny(raw.String(), ".eE") {
		n, err := raw.Float64()
		if err != nil {
			return "", err
		}
		absolute := math.Abs(n)
		if absolute != 0 && (absolute < 1e-4 || absolute >= 1e16) {
			return strconv.FormatFloat(n, 'e', -1, 64), nil
		}
		representation := strconv.FormatFloat(n, 'f', -1, 64)
		parts := strings.SplitN(representation, ".", 2)
		whole, err := commaInteger(json.Number(parts[0]))
		if err != nil {
			return "", err
		}
		if len(parts) == 2 {
			return whole + "." + parts[1], nil
		}
		return whole + ".0", nil
	}
	return commaInteger(value)
}

func duration(value any) (string, error) {
	n, err := integer(value)
	if err != nil {
		return "0s", nil
	}
	day := big.NewInt(86400)
	hour := big.NewInt(3600)
	minute := big.NewInt(60)
	days, remainder := floorDivMod(n, day)
	hours, remainder := floorDivMod(remainder, hour)
	minutes, seconds := floorDivMod(remainder, minute)
	if days.Sign() > 0 {
		return fmt.Sprintf("%sd %sh %sm", days, hours, minutes), nil
	}
	if hours.Sign() > 0 {
		return fmt.Sprintf("%sh %sm", hours, minutes), nil
	}
	return fmt.Sprintf("%sm %ss", minutes, seconds), nil
}

func floorDivMod(value, divisor *big.Int) (*big.Int, *big.Int) {
	quotient, remainder := new(big.Int), new(big.Int)
	quotient.QuoRem(value, divisor, remainder)
	if remainder.Sign() < 0 {
		quotient.Sub(quotient, big.NewInt(1))
		remainder.Add(remainder, divisor)
	}
	return quotient, remainder
}
