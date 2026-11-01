package badges

import (
	"errors"
	"math"
	"strconv"
	"time"
)

const walletChangedBadgeSeconds = 72 * 3600

func recentWalletChange(request Request) (any, error) {
	values, err := arguments(request.Args, 1)
	if err != nil {
		return nil, err
	}
	event, err := object(values[0])
	if err != nil {
		return nil, err
	}
	rawTimestamp := member(event, "payout_wallet_changed_ts", nil)
	if rawTimestamp == nil || rawTimestamp == "" {
		return nil, nil
	}
	var timestamp float64
	switch value := rawTimestamp.(type) {
	case string:
		timestamp, err = parseNumber(value)
	default:
		timestamp, err = number(value)
	}
	if err != nil || timestamp == 0 {
		return nil, nil
	}
	if request.Now-timestamp >= walletChangedBadgeSeconds {
		return nil, nil
	}
	previous := member(event, "payout_wallet_prev8", "?")
	if !truthy(previous) {
		previous = "?"
	}
	old8, err := pythonString(previous)
	if err != nil {
		return nil, err
	}
	wallet := member(event, "payout_wallet", "")
	if !truthy(wallet) {
		wallet = ""
	}
	address, ok := wallet.(string)
	if !ok {
		return nil, errors.New("expected payout wallet string")
	}
	runes := []rune(address)
	if len(runes) > 8 {
		runes = runes[:8]
	}
	return map[string]any{"old8": old8, "new8": string(runes), "ts": timestamp}, nil
}

func parseNumber(value string) (float64, error) {
	result, err := strconv.ParseFloat(value, 64)
	if err != nil || math.IsNaN(result) || math.IsInf(result, 0) {
		return 0, errors.New("expected finite number")
	}
	return result, nil
}

func absoluteTime(timestamp float64, zone string) (string, error) {
	if timestamp == 0 {
		return "Never", nil
	}
	location := time.Local
	if zone != "" {
		loaded, err := time.LoadLocation(zone)
		if err != nil {
			return "", err
		}
		location = loaded
	}
	if timestamp >= math.MaxInt64 || timestamp < math.MinInt64 {
		return "Invalid Time", nil
	}
	seconds, fraction := math.Modf(timestamp)
	return time.Unix(int64(seconds), int64(fraction*1e9)).In(location).Format("15:04:05"), nil
}
