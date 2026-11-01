package charts

import (
	"errors"
	"fmt"
	"math"
	"time"
)

const (
	defaultWindow = "10m"
	defaultUpdate = 30.0
)

var windowColumns = map[string][2]string{
	"1m":  {"v_p2pool_1m", "v_xvb_1m"},
	"10m": {"v_p2pool", "v_xvb"},
	"1h":  {"v_p2pool_1h", "v_xvb_1h"},
	"12h": {"v_p2pool_12h", "v_xvb_12h"},
	"24h": {"v_p2pool_24h", "v_xvb_24h"},
}

var downsampleColumns = []string{
	"v", "v_p2pool_1m", "v_xvb_1m", "v_p2pool", "v_xvb",
	"v_p2pool_1h", "v_xvb_1h", "v_p2pool_12h", "v_xvb_12h",
	"v_p2pool_24h", "v_xvb_24h",
}

type Input struct {
	History        []map[string]any `json:"history"`
	Shares         []map[string]any `json:"shares"`
	Range          string           `json:"range"`
	Window         *[2]float64      `json:"window"`
	AvgWindow      string           `json:"avg_window"`
	Events         []map[string]any `json:"events"`
	RaffleWins     []map[string]any `json:"raffle_wins"`
	Payouts        []map[string]any `json:"payouts"`
	Now            float64          `json:"now"`
	UpdateInterval float64          `json:"update_interval"`
}

func CanonicalWindow(value string) string {
	if _, ok := windowColumns[value]; ok {
		return value
	}
	return defaultWindow
}

func ParseWindow(from, to any) *[2]float64 {
	lo, err := number(from)
	if err != nil {
		return nil
	}
	hi, err := number(to)
	if err != nil || lo <= 0 || hi <= 0 || lo >= hi {
		return nil
	}
	return &[2]float64{lo, hi}
}

func Build(input Input) (map[string]any, error) {
	if input.Now == 0 {
		input.Now = float64(time.Now().UnixNano()) / 1e9
	}
	if input.UpdateInterval == 0 {
		input.UpdateInterval = defaultUpdate
	}
	if !finitePositive(input.Now) || !finitePositive(input.UpdateInterval) {
		return nil, errors.New("invalid chart clock")
	}
	if input.Window != nil {
		if math.IsNaN(input.Window[0]) || math.IsInf(input.Window[0], 0) || math.IsNaN(input.Window[1]) || math.IsInf(input.Window[1], 0) {
			return nil, errors.New("invalid chart window")
		}
	}
	if input.AvgWindow == "" {
		input.AvgWindow = defaultWindow
	}
	history, shares, err := filterRange(input.History, input.Shares, input.Range, input.Window, input.Now)
	if err != nil {
		return nil, err
	}
	duration, err := windowDuration(history, input.Range, input.Window)
	if err != nil {
		return nil, err
	}
	history, err = downsample(history, duration)
	if err != nil {
		return nil, err
	}
	timestamps, err := timestamps(history)
	if err != nil {
		return nil, err
	}
	gaps := gapAfter(timestamps, input.UpdateInterval)
	p2pool := make([]map[string]any, 0, len(history)+len(gaps))
	xvb := make([]map[string]any, 0, len(history)+len(gaps))
	for i, row := range history {
		vp, vx, splitErr := splitValues(row, input.AvgWindow)
		if splitErr != nil {
			return nil, splitErr
		}
		x := int64(timestamps[i] * 1000)
		p2pool = append(p2pool, map[string]any{"x": x, "y": vp})
		xvb = append(xvb, map[string]any{"x": x, "y": vx})
		if gaps[i] {
			mid := int64(((timestamps[i] + timestamps[i+1]) / 2) * 1000)
			p2pool = append(p2pool, map[string]any{"x": mid, "y": nil})
			xvb = append(xvb, map[string]any{"x": mid, "y": nil})
		}
	}
	sharePoints, err := sharesPoints(history, shares)
	if err != nil {
		return nil, err
	}
	events, err := filterEvents(input.Events, input.Range, input.Window, input.Now)
	if err != nil {
		return nil, err
	}
	wins, err := filterEvents(input.RaffleWins, input.Range, input.Window, input.Now)
	if err != nil {
		return nil, err
	}
	payouts, err := filterEvents(input.Payouts, input.Range, input.Window, input.Now)
	if err != nil {
		return nil, err
	}
	eventPoints, err := eventPoints(events)
	if err != nil {
		return nil, err
	}
	rafflePoints, err := rafflePoints(wins)
	if err != nil {
		return nil, err
	}
	payoutPoints, err := payoutPoints(payouts)
	if err != nil {
		return nil, err
	}
	return map[string]any{
		"p2pool": p2pool, "xvb": xvb, "shares": sharePoints, "events": eventPoints,
		"raffle": rafflePoints, "payouts": payoutPoints, "tension": chartTension(duration),
	}, nil
}

func splitValues(row map[string]any, averageWindow string) (float64, float64, error) {
	columns, ok := windowColumns[averageWindow]
	if !ok {
		columns = windowColumns[defaultWindow]
	}
	vp, err := optionalNumber(row, columns[0])
	if err != nil {
		return 0, 0, err
	}
	vx, err := optionalNumber(row, columns[1])
	if err != nil {
		return 0, 0, err
	}
	if averageWindow == defaultWindow && vp == 0 && vx == 0 {
		v, valueErr := optionalNumber(row, "v")
		if valueErr != nil {
			return 0, 0, valueErr
		}
		if v > 0 {
			vp = v
		}
	}
	return vp, vx, nil
}

func finitePositive(value float64) bool {
	return value > 0 && !math.IsNaN(value) && !math.IsInf(value, 0)
}

func fieldNumber(row map[string]any, key string) (float64, error) {
	value, ok := row[key]
	if !ok {
		return 0, fmt.Errorf("missing numeric field %q", key)
	}
	result, err := strictNumber(value)
	if err != nil {
		return 0, fmt.Errorf("invalid numeric field %q", key)
	}
	return result, nil
}

func optionalNumber(row map[string]any, key string) (float64, error) {
	value, ok := row[key]
	if !ok || value == nil {
		return 0, nil
	}
	result, err := strictNumber(value)
	if err != nil {
		return 0, fmt.Errorf("invalid numeric field %q", key)
	}
	return result, nil
}
