package series

import (
	"encoding/json"
	"errors"
	"fmt"
	"math/big"
	"strings"

	"github.com/p2pool-starter-stack/pithead/go/internal/dashboard/domain"
)

const maxChartPoints = 700

var rangeSeconds = map[string]float64{
	"1h":  3600,
	"24h": 86400,
	"1w":  604800,
	"1m":  2592000,
}

func Build(request Request) (any, error) {
	switch request.Operation {
	case "build_share_stats":
		return buildShareStats(request)
	case "_downsample_share_stats":
		return downsampleShareStats(request)
	case "_filter_share_stats":
		return filterShareStats(request)
	case "_window_reject_pct":
		return windowRejectPct(request)
	case "_downsample_gauge_rows":
		return downsampleGaugeRows(request)
	case "build_blocks":
		return buildBlocks(request)
	case "build_payouts":
		return buildPayouts(request)
	case "_gauge_series":
		return gaugeSeries(request)
	case "build_disk_growth":
		return buildNamedGauge(request, []string{"monero_db_bytes", "disk_used_gb", "disk_total_gb"})
	case "build_xvb_history":
		return buildNamedGauge(request, []string{"avg_1h", "avg_24h", "fail_count", "donation_fraction"})
	case "_mode_palette":
		return modePalette(request)
	case "build_hashrate":
		return buildHashrate(request)
	case "build_cadence":
		return buildCadence(request)
	default:
		return nil, errors.New("unsupported series operation")
	}
}

func buildShareStats(request Request) (any, error) {
	rows, rangeArg, window, err := seriesArgs(request.Args)
	if err != nil {
		return nil, err
	}
	filtered, err := filterRows(rows, rangeArg, window, request.Now)
	if err != nil {
		return nil, err
	}
	filtered, err = downsampleShares(filtered, maxChartPoints)
	if err != nil {
		return nil, err
	}
	result := make([]map[string]any, 0, len(filtered))
	for _, row := range filtered {
		x, err := epochMillis(row)
		if err != nil {
			return nil, err
		}
		result = append(result, map[string]any{
			"x": x, "a": rawDefault(row, "accepted"), "r": rawDefault(row, "rejected"),
			"i": rawDefault(row, "invalid"), "e": rawDefault(row, "expired"),
		})
	}
	return result, nil
}

func downsampleShareStats(request Request) (any, error) {
	rows, err := rowsArg(request.Args, 0)
	if err != nil {
		return nil, err
	}
	target, err := optionalInt(request.Args, 1, maxChartPoints)
	if err != nil {
		return nil, err
	}
	return downsampleShares(rows, target)
}

func filterShareStats(request Request) (any, error) {
	rows, rangeArg, window, err := seriesArgs(request.Args)
	if err != nil {
		return nil, err
	}
	return filterRows(rows, rangeArg, window, request.Now)
}

func windowRejectPct(request Request) (any, error) {
	rows, err := rowsArg(request.Args, 0)
	if err != nil {
		return nil, err
	}
	seconds, err := numberArg(request.Args, 1)
	if err != nil {
		return nil, err
	}
	pct, err := domain.ShareRejectPct(rows, seconds, request.Now)
	if err != nil {
		return nil, err
	}
	if pct == nil {
		return "—", nil
	}
	return fmt.Sprintf("%.2f%%", float64(*pct)), nil
}

func downsampleGaugeRows(request Request) (any, error) {
	rows, err := rowsArg(request.Args, 0)
	if err != nil {
		return nil, err
	}
	cols, err := stringsArg(request.Args, 1)
	if err != nil {
		return nil, err
	}
	target, err := optionalInt(request.Args, 2, maxChartPoints)
	if err != nil {
		return nil, err
	}
	return downsampleGauges(rows, cols, target)
}

func buildBlocks(request Request) (any, error) {
	rows, rangeArg, window, err := seriesArgs(request.Args)
	if err != nil {
		return nil, err
	}
	rows, err = filterRows(rows, rangeArg, window, request.Now)
	if err != nil {
		return nil, err
	}
	result := make([]map[string]any, 0, len(rows))
	for _, row := range rows {
		x, err := epochMillis(row)
		if err != nil {
			return nil, err
		}
		result = append(result, map[string]any{"x": x, "height": rawDefault(row, "height"), "difficulty": rawDefault(row, "difficulty")})
	}
	return result, nil
}

func buildPayouts(request Request) (any, error) {
	if len(request.Args) < 2 {
		return nil, errors.New("missing payout arguments")
	}
	var chains map[string][]map[string]any
	if err := decode(request.Args[0], &chains); err != nil {
		return nil, err
	}
	rangeArg, window, err := rangeWindowArgs(request.Args, 1)
	if err != nil {
		return nil, err
	}
	result := map[string]any{}
	for _, chain := range []string{"monero", "tari"} {
		rows, err := filterRows(chains[chain], rangeArg, window, request.Now)
		if err != nil {
			return nil, err
		}
		points := make([]map[string]any, 0, len(rows))
		for _, row := range rows {
			x, err := epochMillis(row)
			if err != nil {
				return nil, err
			}
			points = append(points, map[string]any{"x": x, "amount": rawDefault(row, "amount_atomic")})
		}
		result[chain] = points
	}
	return result, nil
}

func gaugeSeries(request Request) (any, error) {
	if len(request.Args) < 4 {
		return nil, errors.New("missing gauge arguments")
	}
	rows, err := rowsArg(request.Args, 0)
	if err != nil {
		return nil, err
	}
	var rangeArg string
	if err := decode(request.Args[1], &rangeArg); err != nil {
		return nil, err
	}
	window, err := windowArg(request.Args, 2)
	if err != nil {
		return nil, err
	}
	cols, err := stringsArg(request.Args, 3)
	if err != nil {
		return nil, err
	}
	return gaugePoints(rows, rangeArg, window, cols, request.Now)
}

func buildNamedGauge(request Request, cols []string) (any, error) {
	rows, rangeArg, window, err := seriesArgs(request.Args)
	if err != nil {
		return nil, err
	}
	return gaugePoints(rows, rangeArg, window, cols, request.Now)
}

func gaugePoints(rows []map[string]any, rangeArg string, window *[2]float64, cols []string, now float64) (any, error) {
	filtered, err := filterRows(rows, rangeArg, window, now)
	if err != nil {
		return nil, err
	}
	filtered, err = downsampleGauges(filtered, cols, maxChartPoints)
	if err != nil {
		return nil, err
	}
	result := make([]map[string]any, 0, len(filtered))
	for _, row := range filtered {
		x, err := epochMillis(row)
		if err != nil {
			return nil, err
		}
		point := map[string]any{"x": x}
		for _, col := range cols {
			point[col] = rawDefault(row, col)
		}
		result = append(result, point)
	}
	return result, nil
}

func epochMillis(row map[string]any) (any, error) {
	ts, ok := row["ts"]
	if !ok {
		return 0, errors.New("missing timestamp")
	}
	if raw, ok := ts.(json.Number); ok && !strings.ContainsAny(raw.String(), ".eE") {
		if value, valid := new(big.Int).SetString(raw.String(), 10); valid {
			value.Mul(value, big.NewInt(1000))
			return json.Number(value.String()), nil
		}
	}
	value, err := number(ts)
	if err != nil || !finite(value*1000) {
		return 0, errors.New("invalid timestamp")
	}
	integer, _ := new(big.Float).SetFloat64(value * 1000).Int(nil)
	return json.Number(integer.String()), nil
}
