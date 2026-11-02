package fleet

import (
	"encoding/json"
	"errors"
	"math"
	"math/big"
)

type PollError struct {
	Kind    string
	Message string
}

func (e *PollError) Error() string { return e.Message }

func pollValueError(message string) error {
	return &PollError{Kind: "ValueError", Message: message}
}

func pollNumber(value any) (*big.Rat, bool, error) {
	switch value := value.(type) {
	case json.Number:
		if containsFloatSyntax(value.String()) {
			number, err := value.Float64()
			if err != nil || math.IsNaN(number) || math.IsInf(number, 0) {
				return nil, false, errors.New("expected finite number")
			}
			return new(big.Rat).SetFloat64(number), false, nil
		}
		rational, ok := new(big.Rat).SetString(value.String())
		if !ok {
			return nil, false, errors.New("expected number")
		}
		return rational, true, nil
	case float64:
		if math.IsNaN(value) || math.IsInf(value, 0) {
			return nil, false, errors.New("non-finite arithmetic is unsupported")
		}
		return new(big.Rat).SetFloat64(value), false, nil
	case bool:
		if value {
			return big.NewRat(1, 1), true, nil
		}
		return new(big.Rat), true, nil
	default:
		return nil, false, errors.New("expected number")
	}
}

func containsFloatSyntax(value string) bool {
	for _, char := range value {
		if char == '.' || char == 'e' || char == 'E' {
			return true
		}
	}
	return false
}

func pollCompare(value any, target int64) (int, error) {
	if number, ok := value.(float64); ok {
		if math.IsNaN(number) {
			return 0, nil
		}
		if number < float64(target) {
			return -1, nil
		}
		if number > float64(target) {
			return 1, nil
		}
		return 0, nil
	}
	number, _, err := pollNumber(value)
	if err != nil {
		return 0, err
	}
	return number.Cmp(big.NewRat(target, 1)), nil
}

func pollArithmetic(left, right any, operation byte) (any, error) {
	if pollUsesFloat(left) {
		return pollFloatArithmetic(left, right, operation)
	}
	if pollUsesFloat(right) {
		return pollFloatArithmetic(left, right, operation)
	}
	a, aInteger, err := pollNumber(left)
	if err != nil {
		return nil, err
	}
	b, bInteger, err := pollNumber(right)
	if err != nil {
		return nil, err
	}
	result := new(big.Rat)
	switch operation {
	case '+':
		result.Add(a, b)
	case '-':
		result.Sub(a, b)
	case '*':
		result.Mul(a, b)
	default:
		return nil, errors.New("unsupported arithmetic")
	}
	if aInteger && bInteger && result.IsInt() {
		return json.Number(result.Num().String()), nil
	}
	value, _ := result.Float64()
	if math.IsInf(value, 0) {
		return nil, errors.New("numeric result out of range")
	}
	return value, nil
}

func pollUsesFloat(value any) bool {
	if _, ok := value.(float64); ok {
		return true
	}
	number, ok := value.(json.Number)
	return ok && containsFloatSyntax(number.String())
}

func pollFloatArithmetic(left, right any, operation byte) (any, error) {
	a, err := pollFloatOperand(left)
	if err != nil {
		return nil, err
	}
	b, err := pollFloatOperand(right)
	if err != nil {
		return nil, err
	}
	switch operation {
	case '+':
		return a + b, nil
	case '-':
		return a - b, nil
	case '*':
		return a * b, nil
	default:
		return nil, errors.New("unsupported arithmetic")
	}
}

func pollFloatOperand(value any) (float64, error) {
	if number, ok := value.(float64); ok {
		return number, nil
	}
	if number, ok := value.(json.Number); ok && containsFloatSyntax(number.String()) {
		result, err := number.Float64()
		if err != nil && !math.IsInf(result, 0) {
			return 0, err
		}
		return result, nil
	}
	number, _, err := pollNumber(value)
	if err != nil {
		return 0, err
	}
	result, _ := number.Float64()
	if math.IsInf(result, 0) {
		return 0, errors.New("integer too large for float arithmetic")
	}
	return result, nil
}

func pollTruncatedInteger(value float64) (json.Number, error) {
	if math.IsNaN(value) || math.IsInf(value, 0) {
		return "", errors.New("cannot convert non-finite value to integer")
	}
	integer, _ := new(big.Float).SetFloat64(value).Int(nil)
	return json.Number(integer.String()), nil
}

func pollFloat(value any) (float64, error) {
	if result, ok := value.(float64); ok {
		return result, nil
	}
	number, _, err := pollNumber(value)
	if err != nil {
		return 0, err
	}
	result, _ := number.Float64()
	if math.IsInf(result, 0) {
		return 0, errors.New("numeric value out of range")
	}
	return result, nil
}

func pollZero(value any) any {
	if truthy(value) {
		return value
	}
	return json.Number("0")
}

func pollAdd(total, value any) (any, error) {
	return pollArithmetic(total, value, '+')
}
