package domain

import "errors"

func average(history []map[string]any, window, now float64, key string, legacy bool) (float64, error) {
	cutoff := now - window
	total := 0.0
	count := 0
	for _, row := range history {
		if row == nil {
			return 0, errors.New("invalid history row")
		}
		timestampValue, exists := row["timestamp"]
		if !exists {
			timestampValue = 0
		}
		timestamp, err := number(timestampValue)
		if err != nil {
			return 0, err
		}
		if timestamp < cutoff {
			continue
		}
		value, err := number(rawOrZero(row, key))
		if err != nil {
			return 0, err
		}
		if legacy && value == 0 {
			xvb, xvbErr := number(rawOrZero(row, "v_xvb"))
			base, baseErr := number(rawOrZero(row, "v"))
			if xvbErr != nil || baseErr != nil {
				return 0, errors.New("invalid history row")
			}
			if xvb == 0 && base > 0 {
				value = base
			}
		}
		total += value
		count++
	}
	if count == 0 {
		return 0, nil
	}
	return total / float64(count), nil
}

func shareWindow(shares []any, window any, blockTime int, now float64) (int, any, error) {
	windowNumber, err := number(window)
	if err != nil {
		return 0, nil, err
	}
	cutoff := now - windowNumber*float64(blockTime)
	count := 0
	weightInt := int64(0)
	weightFloat := 0.0
	floatWeight := false
	for _, raw := range shares {
		share, ok := raw.(map[string]any)
		if !ok {
			return 0, nil, errors.New("invalid share")
		}
		timestampValue, exists := share["ts"]
		if !exists {
			timestampValue = 0
		}
		timestamp, timestampErr := number(timestampValue)
		if timestampErr != nil {
			return 0, nil, timestampErr
		}
		if timestamp < cutoff {
			continue
		}
		count++
		difficulty := rawOrZero(share, "difficulty")
		if integerOverflow(difficulty) {
			return 0, nil, errors.New("integer overflow")
		}
		if value, ok := integer(difficulty); ok && !floatWeight {
			weightInt, err = addInteger(weightInt, value)
			if err != nil {
				return 0, nil, err
			}
			continue
		}
		value, valueErr := number(difficulty)
		if valueErr != nil {
			return 0, nil, valueErr
		}
		if !floatWeight {
			weightFloat = float64(weightInt)
			floatWeight = true
		}
		weightFloat += value
	}
	if floatWeight {
		return count, PythonFloat(weightFloat), nil
	}
	return count, weightInt, nil
}

func ShareRejectPct(rows []map[string]any, window, now float64) (*PythonFloat, error) {
	cutoff := now - window
	accepted := 0.0
	rejected := 0.0
	for _, row := range rows {
		timestamp, ok := row["ts"]
		if !ok {
			return nil, errors.New("missing share timestamp")
		}
		ts, err := number(timestamp)
		if err != nil {
			return nil, err
		}
		if ts < cutoff {
			continue
		}
		a, aErr := number(rawOrZero(row, "accepted"))
		r, rErr := number(rawOrZero(row, "rejected"))
		if aErr != nil || rErr != nil {
			return nil, errors.New("invalid share count")
		}
		accepted += a
		rejected += r
	}
	total := accepted + rejected
	if total <= 0 {
		return nil, nil
	}
	result := PythonFloat(rejected / total * 100)
	return &result, nil
}
