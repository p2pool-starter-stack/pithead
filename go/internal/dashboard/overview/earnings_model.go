package overview

import (
	"errors"
	"math"
	"time"
)

const (
	atomicPerXMR = 1_000_000_000_000
	microPerXTM  = 1_000_000
	secondsDay   = 86_400
)

func buildXMRPerHSDay(request Request) (any, error) {
	values, err := arguments(request.Args, 2)
	if err != nil {
		return nil, err
	}
	return xmrPerHSDay(values[0], values[1])
}

func buildXTMPerHSDay(request Request) (any, error) {
	values, err := arguments(request.Args, 2)
	if err != nil {
		return nil, err
	}
	return xtmPerHSDay(values[0], values[1])
}

func buildTariSecondsToBlockPerHS(request Request) (any, error) {
	values, err := arguments(request.Args, 1)
	if err != nil {
		return nil, err
	}
	return tariSecondsToBlockPerHS(values[0])
}

func xmrPerHSDay(rewardValue, difficultyValue any) (float64, error) {
	rewardPositive, err := positive(rewardValue)
	if err != nil {
		return 0, err
	}
	difficultyPositive, err := positive(difficultyValue)
	if err != nil {
		return 0, err
	}
	if !rewardPositive || !difficultyPositive {
		return 0, nil
	}
	reward, err := pythonDivide(rewardValue, atomicPerXMR)
	if err != nil {
		return 0, err
	}
	difficulty, err := pythonNumber(difficultyValue)
	if err != nil {
		return 0, err
	}
	return reward / difficulty * secondsDay, nil
}

func xtmPerHSDay(rewardValue, difficultyValue any) (float64, error) {
	rewardPositive, err := positive(rewardValue)
	if err != nil {
		return 0, err
	}
	difficultyPositive, err := positive(difficultyValue)
	if err != nil {
		return 0, err
	}
	if !rewardPositive || !difficultyPositive {
		return 0, nil
	}
	rewardPerDifficulty, err := pythonDivide(rewardValue, difficultyValue)
	if err != nil {
		return 0, err
	}
	return rewardPerDifficulty * secondsDay, nil
}

func tariSecondsToBlockPerHS(value any) (float64, error) {
	difficulty, err := number(value)
	if err != nil {
		return 0, err
	}
	if difficulty <= 0 {
		return 0, nil
	}
	return difficulty, nil
}

func buildPreviousLocalDay(request Request) (any, error) {
	if _, err := arguments(request.Args, 0); err != nil {
		return nil, err
	}
	zone, err := location(request.Zone)
	if err != nil {
		return nil, err
	}
	start, end, err := previousLocalDay(request.Now, zone)
	if err != nil {
		return nil, err
	}
	return []any{start, end}, nil
}

func previousLocalDay(now float64, zone *time.Location) (float64, float64, error) {
	if math.IsNaN(now) || math.IsInf(now, 0) || now >= math.MaxInt64 || now <= math.MinInt64 {
		return 0, 0, errors.New("invalid current time")
	}
	seconds, fraction := math.Modf(now)
	current := time.Unix(int64(seconds), int64(fraction*1e9)).In(zone)
	year, month, day := current.Date()
	end := localDayStart(year, month, day, zone)
	previous := end.Add(-12 * time.Hour).In(zone)
	previousYear, previousMonth, previousDay := previous.Date()
	start := localDayStart(previousYear, previousMonth, previousDay, zone)
	return float64(start.Unix()), float64(end.Unix()), nil
}

func localDayStart(year int, month time.Month, day int, zone *time.Location) time.Time {
	candidate := time.Date(year, month, day, 0, 0, 0, 0, zone)
	candidateYear, candidateMonth, candidateDay := candidate.In(zone).Date()
	if compareDate(candidateYear, candidateMonth, candidateDay, year, month, day) >= 0 {
		return candidate
	}
	low, high := candidate.Unix(), candidate.Add(48*time.Hour).Unix()
	for low+1 < high {
		middle := low + (high-low)/2
		middleYear, middleMonth, middleDay := time.Unix(middle, 0).In(zone).Date()
		if compareDate(middleYear, middleMonth, middleDay, year, month, day) < 0 {
			low = middle
		} else {
			high = middle
		}
	}
	return time.Unix(high, 0).In(zone)
}

func compareDate(leftYear int, leftMonth time.Month, leftDay, rightYear int, rightMonth time.Month, rightDay int) int {
	if leftYear != rightYear {
		if leftYear < rightYear {
			return -1
		}
		return 1
	}
	if leftMonth != rightMonth {
		if leftMonth < rightMonth {
			return -1
		}
		return 1
	}
	if leftDay < rightDay {
		return -1
	}
	if leftDay > rightDay {
		return 1
	}
	return 0
}

func buildConfirmedPayoutsSummary(request Request) (any, error) {
	values, err := arguments(request.Args, 4)
	if err != nil {
		return nil, err
	}
	if values[0] == nil {
		return map[string]any{"enabled": false}, nil
	}
	unit := pythonString(values[2])
	zone, err := location(request.Zone)
	if err != nil {
		return nil, err
	}
	return confirmedPayoutsSummary(values[0], request.Now, zone, values[1], unit, values[3])
}

func confirmedPayoutsSummary(payoutValue any, now float64, zone *time.Location, divisor any, unit string, walletValue any) (map[string]any, error) {
	if payoutValue == nil {
		return map[string]any{"enabled": false}, nil
	}
	payouts, err := array(payoutValue)
	if err != nil {
		return nil, err
	}
	yStart, yEnd, err := previousLocalDay(now, zone)
	if err != nil {
		return nil, err
	}
	starts := map[string]float64{"yesterday": yStart, "7d": now - 7*secondsDay, "30d": now - 30*secondsDay}
	totals := map[string]*pythonSum{}
	for _, window := range []string{"24h", "yesterday", "7d", "30d", "all"} {
		totals[window] = newPythonSum()
	}
	stamps := make([]float64, 0, len(payouts))
	n30d := 0
	for _, value := range payouts {
		payout, err := object(value)
		if err != nil {
			return nil, err
		}
		amountValue := member(payout, "amount_atomic", 0)
		if !truthy(amountValue) {
			amountValue = 0
		}
		timestampValue := member(payout, "ts", 0)
		if !truthy(timestampValue) {
			timestampValue = 0
		}
		stamp, err := number(timestampValue)
		if err != nil {
			return nil, err
		}
		if err := totals["all"].add(amountValue); err != nil {
			return nil, err
		}
		if stamp >= starts["30d"] {
			if err := totals["30d"].add(amountValue); err != nil {
				return nil, err
			}
			n30d++
		}
		if stamp >= starts["7d"] {
			if err := totals["7d"].add(amountValue); err != nil {
				return nil, err
			}
		}
		if stamp >= now-secondsDay {
			if err := totals["24h"].add(amountValue); err != nil {
				return nil, err
			}
		}
		if stamp >= yStart && stamp < yEnd {
			if err := totals["yesterday"].add(amountValue); err != nil {
				return nil, err
			}
		}
		if stamp > 0 {
			stamps = append(stamps, stamp)
		}
	}
	since, last := extrema(stamps)
	partial := map[string]any{}
	for _, window := range []string{"yesterday", "7d", "30d"} {
		partial[window] = since <= 0 || since > starts[window]
	}
	result := map[string]any{
		"enabled": true, "count": len(payouts), "last_ts": last, "since_ts": since,
		"partial": partial, "n_30d": n30d,
	}
	for window, total := range totals {
		value, err := total.divide(divisor)
		if err != nil {
			return nil, err
		}
		result[unit+"_"+window] = value
	}
	if !truthy(walletValue) {
		result["reachable"] = nil
		return result, nil
	}
	wallet, err := object(walletValue)
	if err != nil {
		return nil, err
	}
	for key, value := range wallet {
		result[key] = value
	}
	return result, nil
}

func extrema(values []float64) (float64, float64) {
	if len(values) == 0 {
		return 0, 0
	}
	lowest, highest := values[0], values[0]
	for _, value := range values[1:] {
		if value < lowest {
			lowest = value
		}
		if value > highest {
			highest = value
		}
	}
	return lowest, highest
}
