package series

import (
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"math/big"
	"strconv"
	"strings"
	"time"
)

func modePalette(request Request) (any, error) {
	if len(request.Args) < 1 {
		return nil, errors.New("missing mode")
	}
	var mode string
	if err := decode(request.Args[0], &mode); err != nil {
		return nil, err
	}
	if strings.Contains(mode, "Split") {
		return []string{"accent", "ok", "purple"}, nil
	}
	if strings.Contains(mode, "XVB") {
		return []string{"purple", "muted", "purple"}, nil
	}
	return []string{"ok", "ok", "muted"}, nil
}

func buildHashrate(request Request) (any, error) {
	if len(request.Args) < 4 {
		return nil, errors.New("missing hashrate arguments")
	}
	var metrics map[string]any
	if err := decode(request.Args[0], &metrics); err != nil {
		return nil, err
	}
	for _, key := range []string{
		"mode", "total_h15", "p2pool_1h", "p2pool_24h", "xvb_1h", "xvb_24h",
		"xvb_routed_1h", "xvb_routed_24h", "current_tier", "target_tier", "xvb_fail_count",
		"xvb_last_update", "xvb_stale", "low_hr_warning",
	} {
		if _, ok := metrics[key]; !ok {
			return nil, errors.New("missing " + key)
		}
	}
	tokens := make([]string, 3)
	for i := range tokens {
		if err := decode(request.Args[i+1], &tokens[i]); err != nil {
			return nil, err
		}
	}
	location, err := zone(request.Zone)
	if err != nil {
		return nil, err
	}
	updated, err := formatTimeAbs(metrics["xvb_last_update"], location)
	if err != nil {
		return nil, err
	}
	result := map[string]any{
		"mode_name": rawRequired(metrics, "mode"), "mode_variant": tokens[0],
		"total": formatHashrate(metrics["total_h15"]), "p2p_1h": formatHashrate(metrics["p2pool_1h"]),
		"p2p_24h": formatHashrate(metrics["p2pool_24h"]), "p2p_variant": tokens[1],
		"xvb_1h": formatHashrate(metrics["xvb_1h"]), "xvb_24h": formatHashrate(metrics["xvb_24h"]),
		"xvb_routed_1h": formatHashrate(metrics["xvb_routed_1h"]), "xvb_routed_24h": formatHashrate(metrics["xvb_routed_24h"]),
		"xvb_variant": tokens[2], "tier": rawRequired(metrics, "current_tier"),
		"target_tier": rawRequired(metrics, "target_tier"), "xvb_fail_count": rawRequired(metrics, "xvb_fail_count"),
		"xvb_updated": updated, "xvb_stale": rawRequired(metrics, "xvb_stale"), "low_hr": nil,
	}
	if truthy(metrics["low_hr_warning"]) {
		result["low_hr"] = map[string]any{
			"text":  "⚠ Hashrate low for tier",
			"title": "Your hashrate can't sustain the selected XvB donation tier; donation will fall short of it.",
		}
	}
	return result, nil
}

func buildCadence(request Request) (any, error) {
	if len(request.Args) < 1 {
		return nil, errors.New("missing metrics")
	}
	var metrics map[string]any
	if err := decode(request.Args[0], &metrics); err != nil {
		return nil, err
	}
	location, err := zone(request.Zone)
	if err != nil {
		return nil, err
	}
	lastBlockValue, present := metrics["last_block_ts"]
	if !present {
		return nil, errors.New("missing last_block_ts")
	}
	if !truthy(lastBlockValue) {
		lastBlockValue = 0
	}
	lastBlock, err := number(lastBlockValue)
	if err != nil {
		return nil, err
	}
	expected, err := requiredNumber(metrics, "expected_share_sec")
	if err != nil {
		return nil, err
	}
	luck, err := requiredNumber(metrics, "luck_pct")
	if err != nil {
		return nil, err
	}
	weight, err := requiredNumber(metrics, "own_pplns_weight")
	if err != nil {
		return nil, err
	}
	lastBlockText, err := formatTimeAbs(metrics["last_block_ts"], location)
	if err != nil {
		return nil, err
	}
	available := expected > 0
	result := map[string]any{
		"last_block": lastBlockText, "since_block": "—", "tts": "—", "luck": "—",
		"weight": groupedRounded(weight), "available": available,
	}
	if lastBlock != 0 {
		if !finite(request.Now - lastBlock) {
			return nil, errors.New("invalid elapsed block time")
		}
		result["since_block"] = formatDuration(request.Now - lastBlock)
	}
	if available {
		result["tts"] = formatDuration(expected)
		result["luck"] = fmt.Sprintf("%.0f%%", luck)
	}
	return result, nil
}

func formatHashrate(value any) string {
	n, err := number(value)
	if text, ok := value.(string); ok {
		n, err = strconv.ParseFloat(text, 64)
		if err == nil && !finite(n) {
			err = errors.New("not finite")
		}
	}
	if err != nil {
		return "0 H/s"
	}
	switch {
	case n >= 1_000_000_000:
		return fmt.Sprintf("%.2f GH/s", n/1_000_000_000)
	case n >= 1_000_000:
		return fmt.Sprintf("%.2f MH/s", n/1_000_000)
	case n >= 1_000:
		return fmt.Sprintf("%.2f kH/s", n/1_000)
	default:
		return fmt.Sprintf("%.2f H/s", n)
	}
}

func formatDuration(seconds float64) string {
	value, _ := new(big.Float).SetFloat64(seconds).Int(nil)
	days := new(big.Int).Div(value, big.NewInt(86400))
	hours := new(big.Int).Mod(new(big.Int).Div(value, big.NewInt(3600)), big.NewInt(24))
	minutes := new(big.Int).Mod(new(big.Int).Div(value, big.NewInt(60)), big.NewInt(60))
	secs := new(big.Int).Mod(value, big.NewInt(60))
	if days.Sign() > 0 {
		return fmt.Sprintf("%sd %sh %sm", days, hours, minutes)
	}
	if hours.Sign() > 0 {
		return fmt.Sprintf("%sh %sm", hours, minutes)
	}
	return fmt.Sprintf("%sm %ss", minutes, secs)
}

func formatTimeAbs(value any, location *time.Location) (string, error) {
	if !truthy(value) {
		return "Never", nil
	}
	timestamp, err := number(value)
	if err != nil {
		return "Invalid Time", nil
	}
	if timestamp == 0 {
		return "Never", nil
	}
	if timestamp >= math.MaxInt64 || timestamp < math.MinInt64 {
		return "", errors.New("unsupported local timestamp")
	}
	seconds, fraction := math.Modf(timestamp)
	return time.Unix(int64(seconds), int64(fraction*1e9)).In(location).Format("15:04:05"), nil
}

func zone(name string) (*time.Location, error) {
	if name == "" {
		return time.Local, nil
	}
	return time.LoadLocation(name)
}

func groupedRounded(value float64) string {
	integer := fmt.Sprintf("%.0f", value)
	sign := ""
	if strings.HasPrefix(integer, "-") {
		sign, integer = "-", integer[1:]
	}
	for i := len(integer) - 3; i > 0; i -= 3 {
		integer = integer[:i] + "," + integer[i:]
	}
	return sign + integer
}

func requiredNumber(values map[string]any, key string) (float64, error) {
	value, ok := values[key]
	if !ok {
		return 0, errors.New("missing " + key)
	}
	return number(value)
}

func rawRequired(values map[string]any, key string) any {
	value, ok := values[key]
	if !ok {
		return json.Number("0")
	}
	return value
}
