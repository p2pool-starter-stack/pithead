package charts

import (
	"fmt"
	"math"
	"sort"
)

var rangeSeconds = map[string]float64{"1h": 3600, "24h": 86400, "1w": 604800, "1m": 2592000}

func filterRange(history, shares []map[string]any, rangeValue string, window *[2]float64, now float64) ([]map[string]any, []map[string]any, error) {
	filteredHistory := make([]map[string]any, 0, len(history))
	filteredShares := make([]map[string]any, 0, len(shares))
	lo, hi, bounded := bounds(rangeValue, window, now)
	for _, row := range history {
		ts, err := fieldNumber(row, "timestamp")
		if err != nil {
			return nil, nil, err
		}
		if !bounded || ts >= lo && ts <= hi {
			filteredHistory = append(filteredHistory, row)
		}
	}
	for _, row := range shares {
		ts, err := fieldNumber(row, "ts")
		if err != nil {
			return nil, nil, err
		}
		if !bounded || ts >= lo && ts <= hi {
			filteredShares = append(filteredShares, row)
		}
	}
	return filteredHistory, filteredShares, nil
}

func filterEvents(events []map[string]any, rangeValue string, window *[2]float64, now float64) ([]map[string]any, error) {
	filtered := make([]map[string]any, 0, len(events))
	lo, hi, bounded := bounds(rangeValue, window, now)
	for _, row := range events {
		ts, err := fieldNumber(row, "ts")
		if err != nil {
			return nil, err
		}
		if !bounded || ts >= lo && ts <= hi {
			filtered = append(filtered, row)
		}
	}
	return filtered, nil
}

func bounds(rangeValue string, window *[2]float64, now float64) (float64, float64, bool) {
	if window != nil {
		return window[0], window[1], true
	}
	seconds := rangeSeconds[rangeValue]
	if rangeValue == "all" || seconds <= 0 {
		return 0, 0, false
	}
	return now - seconds, math.MaxFloat64, true
}

func windowDuration(history []map[string]any, rangeValue string, window *[2]float64) (float64, error) {
	if window != nil {
		return math.Max(0, window[1]-window[0]), nil
	}
	if seconds := rangeSeconds[rangeValue]; seconds > 0 {
		return seconds, nil
	}
	if len(history) < 2 {
		return 0, nil
	}
	first, err := fieldNumber(history[0], "timestamp")
	if err != nil {
		return 0, err
	}
	last, err := fieldNumber(history[len(history)-1], "timestamp")
	if err != nil {
		return 0, err
	}
	if last < first {
		return 0, nil
	}
	return last - first, nil
}

func timestamps(history []map[string]any) ([]float64, error) {
	result := make([]float64, len(history))
	for i, row := range history {
		value, err := fieldNumber(row, "timestamp")
		if err != nil {
			return nil, err
		}
		result[i] = value
	}
	return result, nil
}

func gapAfter(stamps []float64, updateInterval float64) map[int]bool {
	result := make(map[int]bool)
	if len(stamps) < 2 {
		return result
	}
	deltas := make([]float64, len(stamps)-1)
	for i := range deltas {
		deltas[i] = stamps[i+1] - stamps[i]
	}
	ordered := append([]float64(nil), deltas...)
	sort.Float64s(ordered)
	threshold := 3 * ordered[len(ordered)/2]
	if floor := 2 * updateInterval; threshold < floor {
		threshold = floor
	}
	for i, delta := range deltas {
		if delta > threshold {
			result[i] = true
		}
	}
	return result
}

func targetPoints(duration float64) int {
	for _, tier := range []struct {
		limit  float64
		points int
	}{{3600, 0}, {21600, 360}, {86400, 480}, {604800, 600}} {
		if duration <= tier.limit {
			return tier.points
		}
	}
	return 700
}

func chartTension(duration float64) float64 {
	for _, tier := range []struct {
		limit   float64
		tension float64
	}{{3600, 0}, {86400, 0.2}, {604800, 0.35}} {
		if duration <= tier.limit {
			return tier.tension
		}
	}
	return 0.4
}

func downsample(history []map[string]any, duration float64) ([]map[string]any, error) {
	target := targetPoints(duration)
	if target <= 0 || len(history) <= target {
		return history, nil
	}
	chunkSize := float64(len(history)) / float64(target)
	result := make([]map[string]any, 0, target)
	for i := 0; i < target; i++ {
		start, end := int(float64(i)*chunkSize), int(float64(i+1)*chunkSize)
		chunk := history[start:end]
		if len(chunk) == 0 {
			continue
		}
		mid := chunk[len(chunk)/2]
		stamp, err := fieldNumber(mid, "timestamp")
		if err != nil {
			return nil, err
		}
		label, ok := mid["t"]
		if !ok {
			return nil, fmt.Errorf("missing field %q", "t")
		}
		row := map[string]any{"t": label, "timestamp": stamp}
		for _, column := range downsampleColumns {
			sum := 0.0
			for _, item := range chunk {
				value, valueErr := optionalNumber(item, column)
				if valueErr != nil {
					return nil, valueErr
				}
				sum += value
			}
			value, roundErr := pythonRound(sum/float64(len(chunk)), 2)
			if roundErr != nil {
				return nil, roundErr
			}
			row[column] = value
		}
		result = append(result, row)
	}
	return result, nil
}
