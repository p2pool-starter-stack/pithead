package charts

import (
	"encoding/json"
	"errors"
	"fmt"
	"sort"
	"time"
)

func sharesPoints(history, shares []map[string]any) ([]map[string]any, error) {
	points := make([]map[string]any, 0)
	if len(history) == 0 || len(shares) == 0 {
		return points, nil
	}
	stamps, err := timestamps(history)
	if err != nil {
		return nil, err
	}
	counts := make(map[int]int)
	for _, share := range shares {
		stamp, stampErr := fieldNumber(share, "ts")
		if stampErr != nil {
			return nil, stampErr
		}
		index := sort.SearchFloat64s(stamps, stamp)
		closest := -1
		if index < len(stamps) {
			closest = index
		}
		if index > 0 && (closest < 0 || abs(stamps[index-1]-stamp) < abs(stamps[closest]-stamp)) {
			closest = index - 1
		}
		if closest >= 0 {
			counts[closest]++
		}
	}
	indices := make([]int, 0, len(counts))
	for index := range counts {
		indices = append(indices, index)
	}
	sort.Ints(indices)
	for _, index := range indices {
		count := counts[index]
		radius := 6 + count*3
		if radius > 15 {
			radius = 15
		}
		points = append(points, map[string]any{"x": int64(stamps[index] * 1000), "y": 0.93, "r": radius, "c": count})
	}
	return points, nil
}

func eventPoints(events []map[string]any) ([]map[string]any, error) {
	points := make([]map[string]any, 0, len(events))
	for _, event := range events {
		stamp, err := fieldNumber(event, "ts")
		if err != nil {
			return nil, err
		}
		kind, hasKind := event["type"]
		if !hasKind {
			kind = ""
		}
		label := event["detail"]
		if !truthy(label) {
			if hasKind {
				label = kind
			} else {
				label = "event"
			}
		}
		points = append(points, map[string]any{"x": int64(stamp * 1000), "y": 0.82, "kind": kind, "label": label})
	}
	return points, nil
}

func rafflePoints(wins []map[string]any) ([]map[string]any, error) {
	points := make([]map[string]any, 0, len(wins))
	for _, win := range wins {
		stamp, err := fieldNumber(win, "ts")
		if err != nil {
			return nil, err
		}
		tier, ok := win["tier"]
		if !ok {
			return nil, errors.New("missing raffle tier")
		}
		hashrate, ok := win["hashrate"]
		if !ok {
			return nil, errors.New("missing raffle hashrate")
		}
		label := fmt.Sprintf("XvB raffle win — %v round at %s", tier, formatHashrate(hashrate))
		points = append(points, map[string]any{"x": int64(stamp * 1000), "y": 0.70, "label": label})
	}
	return points, nil
}

func payoutPoints(payouts []map[string]any) ([]map[string]any, error) {
	if len(payouts) > 200 {
		payouts = payouts[:200]
	}
	points := make([]map[string]any, 0, len(payouts))
	for _, payout := range payouts {
		stamp, err := fieldNumber(payout, "ts")
		if err != nil {
			return nil, err
		}
		amount, err := optionalNumber(payout, "amount_atomic")
		if err != nil {
			return nil, err
		}
		date := time.Unix(int64(stamp), int64((stamp-float64(int64(stamp)))*1e9)).In(time.Local).Format("2006-01-02")
		label := fmt.Sprintf("%.6f XMR — %s", amount/1_000_000_000_000, date)
		points = append(points, map[string]any{"x": int64(stamp * 1000), "y": 0.58, "label": label})
	}
	return points, nil
}

func truthy(value any) bool {
	switch value := value.(type) {
	case nil:
		return false
	case string:
		return value != ""
	case bool:
		return value
	case float64:
		return value != 0
	case int:
		return value != 0
	case json.Number:
		n, err := value.Float64()
		return err == nil && n != 0
	case []any:
		return len(value) != 0
	case map[string]any:
		return len(value) != 0
	default:
		return true
	}
}

func abs(value float64) float64 {
	if value < 0 {
		return -value
	}
	return value
}
