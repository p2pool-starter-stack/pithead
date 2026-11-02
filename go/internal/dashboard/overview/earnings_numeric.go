package overview

import (
	"encoding/json"
	"errors"
	"math"
	"math/big"
	"strings"
)

type pythonSum struct {
	integer  *big.Int
	floating float64
	isFloat  bool
}

func newPythonSum() *pythonSum {
	return &pythonSum{integer: new(big.Int)}
}

func pythonDivide(numerator, divisor any) (float64, error) {
	sum := newPythonSum()
	if err := sum.add(numerator); err != nil {
		return 0, err
	}
	return sum.divide(divisor)
}

func pythonNumber(value any) (float64, error) {
	integer, isInteger, err := pythonInteger(value)
	if err != nil {
		return 0, err
	}
	return pythonFloat(value, integer, isInteger)
}

func (sum *pythonSum) add(value any) error {
	integer, isInteger, err := pythonInteger(value)
	if err != nil {
		return err
	}
	if isInteger && !sum.isFloat {
		sum.integer.Add(sum.integer, integer)
		return nil
	}
	addend, err := pythonFloat(value, integer, isInteger)
	if err != nil {
		return err
	}
	if !sum.isFloat {
		sum.floating, err = bigIntegerFloat(sum.integer)
		if err != nil {
			return err
		}
		sum.isFloat = true
	}
	sum.floating += addend
	return nil
}

func (sum *pythonSum) divide(value any) (float64, error) {
	divisorInteger, divisorIsInteger, err := pythonInteger(value)
	if err != nil {
		return 0, err
	}
	if divisorIsInteger && divisorInteger.Sign() == 0 {
		return 0, errors.New("invalid payout divisor")
	}
	if !sum.isFloat && divisorIsInteger {
		result, _ := new(big.Rat).SetFrac(sum.integer, divisorInteger).Float64()
		if math.IsInf(result, 0) {
			return 0, errors.New("integer division result too large for float")
		}
		return result, nil
	}
	divisor, err := pythonFloat(value, divisorInteger, divisorIsInteger)
	if err != nil || divisor == 0 {
		return 0, errors.New("invalid payout divisor")
	}
	numerator := sum.floating
	if !sum.isFloat {
		numerator, err = bigIntegerFloat(sum.integer)
		if err != nil {
			return 0, err
		}
	}
	return numerator / divisor, nil
}

func pythonInteger(value any) (*big.Int, bool, error) {
	switch value := value.(type) {
	case bool:
		if value {
			return big.NewInt(1), true, nil
		}
		return new(big.Int), true, nil
	case int:
		return big.NewInt(int64(value)), true, nil
	case int64:
		return big.NewInt(value), true, nil
	case json.Number:
		if !strings.ContainsAny(value.String(), ".eE") {
			if integer, ok := new(big.Int).SetString(value.String(), 10); ok {
				return integer, true, nil
			}
		}
	case float64:
	default:
		return nil, false, errors.New("expected number")
	}
	if _, err := number(value); err != nil {
		return nil, false, err
	}
	return nil, false, nil
}

func pythonFloat(value any, integer *big.Int, isInteger bool) (float64, error) {
	if isInteger {
		return bigIntegerFloat(integer)
	}
	return number(value)
}

func bigIntegerFloat(value *big.Int) (float64, error) {
	result, _ := new(big.Float).SetInt(value).Float64()
	if math.IsInf(result, 0) {
		return 0, errors.New("integer too large to convert to float")
	}
	return result, nil
}
