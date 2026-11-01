package series

import (
	"encoding/json"
	"errors"
	"math"
)

func rowsArg(args []json.RawMessage, index int) ([]map[string]any, error) {
	if index >= len(args) {
		return nil, errors.New("missing rows")
	}
	var rows []map[string]any
	if err := decode(args[index], &rows); err != nil {
		return nil, err
	}
	if rows == nil {
		return nil, errors.New("rows must be an array")
	}
	return rows, nil
}

func seriesArgs(args []json.RawMessage) ([]map[string]any, string, *[2]float64, error) {
	rows, err := rowsArg(args, 0)
	if err != nil {
		return nil, "", nil, err
	}
	rangeArg, window, err := rangeWindowArgs(args, 1)
	return rows, rangeArg, window, err
}

func rangeWindowArgs(args []json.RawMessage, index int) (string, *[2]float64, error) {
	if index >= len(args) {
		return "", nil, errors.New("missing range")
	}
	var rangeArg string
	if err := decode(args[index], &rangeArg); err != nil {
		return "", nil, err
	}
	window, err := windowArg(args, index+1)
	return rangeArg, window, err
}

func windowArg(args []json.RawMessage, index int) (*[2]float64, error) {
	if index >= len(args) || string(args[index]) == "null" {
		return nil, nil
	}
	var values []float64
	if err := decode(args[index], &values); err != nil {
		return nil, err
	}
	if len(values) != 2 || !finite(values[0]) || !finite(values[1]) {
		return nil, errors.New("invalid window")
	}
	return &[2]float64{values[0], values[1]}, nil
}

func stringsArg(args []json.RawMessage, index int) ([]string, error) {
	if index >= len(args) {
		return nil, errors.New("missing columns")
	}
	var values []string
	if err := decode(args[index], &values); err != nil {
		return nil, err
	}
	if values == nil {
		return nil, errors.New("columns must be an array")
	}
	return values, nil
}

func numberArg(args []json.RawMessage, index int) (float64, error) {
	if index >= len(args) {
		return 0, errors.New("missing number")
	}
	var value any
	if err := decode(args[index], &value); err != nil {
		return 0, err
	}
	return number(value)
}

func optionalInt(args []json.RawMessage, index, fallback int) (int, error) {
	if index >= len(args) {
		return fallback, nil
	}
	var value any
	if err := decode(args[index], &value); err != nil {
		return 0, err
	}
	integerValue, ok := integer(value)
	if !ok || integerValue > math.MaxInt || integerValue < math.MinInt {
		return 0, errors.New("invalid integer")
	}
	return int(integerValue), nil
}

func finite(value float64) bool {
	return !math.IsNaN(value) && !math.IsInf(value, 0)
}
