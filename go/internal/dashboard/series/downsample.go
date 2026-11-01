package series

import (
	"encoding/json"
	"errors"
	"fmt"
	"math/big"
	"strconv"
	"strings"

	"github.com/p2pool-starter-stack/pithead/go/internal/dashboard/domain"
)

func filterRows(rows []map[string]any, rangeArg string, window *[2]float64, now float64) ([]map[string]any, error) {
	if window == nil && (rangeArg == "all" || rangeSeconds[rangeArg] <= 0) {
		return rows, nil
	}
	result := make([]map[string]any, 0, len(rows))
	for _, row := range rows {
		raw, ok := row["ts"]
		if !ok {
			return nil, errors.New("missing timestamp")
		}
		ts, err := number(raw)
		if err != nil {
			return nil, err
		}
		keep := ts >= now-rangeSeconds[rangeArg]
		if window != nil {
			keep = ts >= window[0] && ts <= window[1]
		}
		if keep {
			result = append(result, row)
		}
	}
	return result, nil
}

func downsampleShares(rows []map[string]any, target int) ([]map[string]any, error) {
	if len(rows) <= target {
		return rows, nil
	}
	if target == 0 {
		return nil, errors.New("division by zero")
	}
	if target < 0 {
		return []map[string]any{}, nil
	}
	chunkSize := float64(len(rows)) / float64(target)
	result := make([]map[string]any, 0, target)
	for i := 0; i < target; i++ {
		lo, hi := int(float64(i)*chunkSize), int(float64(i+1)*chunkSize)
		if lo == hi {
			continue
		}
		chunk := rows[lo:hi]
		ts, ok := chunk[len(chunk)/2]["ts"]
		if !ok {
			return nil, errors.New("missing timestamp")
		}
		bucket := map[string]any{"ts": ts}
		for _, col := range []string{"accepted", "rejected", "invalid", "expired"} {
			total, err := sumValues(chunk, col)
			if err != nil {
				return nil, err
			}
			bucket[col] = total
		}
		result = append(result, bucket)
	}
	return result, nil
}

func downsampleGauges(rows []map[string]any, cols []string, target int) ([]map[string]any, error) {
	if len(rows) <= target {
		return rows, nil
	}
	if target == 0 {
		return nil, errors.New("division by zero")
	}
	if target < 0 {
		return []map[string]any{}, nil
	}
	chunkSize := float64(len(rows)) / float64(target)
	result := make([]map[string]any, 0, target)
	for i := 0; i < target; i++ {
		lo, hi := int(float64(i)*chunkSize), int(float64(i+1)*chunkSize)
		if lo == hi {
			continue
		}
		chunk := rows[lo:hi]
		ts, ok := chunk[len(chunk)/2]["ts"]
		if !ok {
			return nil, errors.New("missing timestamp")
		}
		bucket := map[string]any{"ts": ts}
		for _, col := range cols {
			average, err := averageValues(chunk, col)
			if err != nil {
				return nil, err
			}
			bucket[col] = domain.PythonFloat(roundEven(average, 2))
		}
		result = append(result, bucket)
	}
	return result, nil
}

func sumValues(rows []map[string]any, key string) (any, error) {
	total := newPythonSum()
	for _, row := range rows {
		if err := total.add(rawOrZero(row, key)); err != nil {
			return nil, err
		}
	}
	return total.value()
}

func averageValues(rows []map[string]any, key string) (float64, error) {
	total := newPythonSum()
	for _, row := range rows {
		if err := total.add(rawOrZero(row, key)); err != nil {
			return 0, err
		}
	}
	if total.floating {
		result := total.float / float64(len(rows))
		if !finite(result) {
			return 0, errors.New("not finite")
		}
		return result, nil
	}
	ratio := new(big.Rat).SetFrac(&total.integer, big.NewInt(int64(len(rows))))
	result, _ := ratio.Float64()
	if !finite(result) {
		return 0, errors.New("not finite")
	}
	return result, nil
}

type pythonSum struct {
	integer  big.Int
	float    float64
	floating bool
}

func newPythonSum() *pythonSum {
	return &pythonSum{}
}

func (sum *pythonSum) add(value any) error {
	if integerValue, ok := arbitraryInteger(value); ok {
		if !sum.floating {
			sum.integer.Add(&sum.integer, integerValue)
			return nil
		}
		converted, _ := new(big.Float).SetInt(integerValue).Float64()
		if !finite(converted) {
			return errors.New("integer cannot be represented as float")
		}
		sum.float += converted
	} else {
		converted, err := number(value)
		if err != nil {
			return err
		}
		if !sum.floating {
			sum.float, _ = new(big.Float).SetInt(&sum.integer).Float64()
			if !finite(sum.float) {
				return errors.New("integer cannot be represented as float")
			}
			sum.floating = true
		}
		sum.float += converted
	}
	if !finite(sum.float) {
		return errors.New("not finite")
	}
	return nil
}

func (sum *pythonSum) value() (any, error) {
	if sum.floating {
		return domain.PythonFloat(sum.float), nil
	}
	if sum.integer.IsInt64() {
		return sum.integer.Int64(), nil
	}
	return json.Number(sum.integer.String()), nil
}

func arbitraryInteger(value any) (*big.Int, bool) {
	result := new(big.Int)
	switch value := value.(type) {
	case json.Number:
		if strings.ContainsAny(value.String(), ".eE") {
			return nil, false
		}
		result, ok := result.SetString(value.String(), 10)
		return result, ok
	case int:
		return result.SetInt64(int64(value)), true
	case int64:
		return result.SetInt64(value), true
	case int32:
		return result.SetInt64(int64(value)), true
	case uint:
		return result.SetUint64(uint64(value)), true
	case uint64:
		return result.SetUint64(value), true
	case uint32:
		return result.SetUint64(uint64(value)), true
	case bool:
		if value {
			return result.SetInt64(1), true
		}
		return result, true
	default:
		return nil, false
	}
}

func roundEven(value float64, places int) float64 {
	result, _ := strconv.ParseFloat(fmt.Sprintf("%.*f", places, value), 64)
	return result
}
