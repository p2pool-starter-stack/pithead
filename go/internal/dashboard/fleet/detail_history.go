package fleet

import (
	"errors"

	"github.com/p2pool-starter-stack/pithead/go/internal/dashboard/series"
)

func buildWorkerHashrateHistory(request Request) (any, error) {
	values, err := detailArguments(request, 4)
	if err != nil {
		return nil, err
	}
	return workerHashrateHistory(values, request)
}

func workerHashrateHistory(values []any, request Request) (any, error) {
	samples, ok := values[0].([]any)
	if !ok {
		return nil, errors.New("expected worker samples")
	}
	markers, ok := values[1].([]any)
	if !ok {
		return nil, errors.New("expected worker markers")
	}
	rangeArg, ok := values[2].(string)
	if !ok {
		return nil, errors.New("expected range")
	}
	sampleRows, err := detailRows(samples)
	if err != nil {
		return nil, err
	}
	markerRows, err := detailRows(markers)
	if err != nil {
		return nil, err
	}
	var window *[2]float64
	if values[3] != nil {
		bounds, err := array(values[3])
		if err != nil || len(bounds) != 2 {
			return nil, errors.New("invalid worker window")
		}
		lo, loOK := numeric(bounds[0])
		hi, hiOK := numeric(bounds[1])
		if !loOK || !hiOK {
			return nil, errors.New("invalid worker window")
		}
		window = &[2]float64{lo, hi}
	}
	hashrate, err := series.GaugePoints(sampleRows, rangeArg, window, []string{"h15"}, request.Now)
	if err != nil {
		return nil, err
	}
	rows, err := series.FilterRows(markerRows, rangeArg, window, request.Now)
	if err != nil {
		return nil, err
	}
	points, ok := hashrate.([]map[string]any)
	if !ok {
		return nil, errors.New("invalid hashrate series")
	}
	line := make([]any, 0, len(points))
	for _, point := range points {
		line = append(line, map[string]any{"x": point["x"], "y": point["h15"]})
	}
	events := make([]any, 0, len(rows))
	for _, row := range rows {
		x, err := series.EpochMillis(row["ts"])
		if err != nil {
			return nil, err
		}
		changes := member(row, "changes", nil)
		if !truthy(changes) {
			changes = map[string]any{}
		}
		events = append(events, map[string]any{
			"x": x, "status": member(row, "status", nil), "type": member(row, "type", "apply"),
			"changes": changes, "reason": member(row, "reason", nil),
		})
	}
	return map[string]any{"hashrate": line, "markers": events}, nil
}
