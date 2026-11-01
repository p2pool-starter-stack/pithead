package resources

import "errors"

const (
	gib        = 1024 * 1024 * 1024
	window     = 7 * 86400
	maxRows    = 169
	minSamples = 24
	maxGap     = 3 * 3600
)

type historyPoint struct {
	row       map[string]any
	timestamp float64
	used      float64
	total     float64
}

func capacityOutlook(rows []any, filesystem map[string]any, now float64) (map[string]any, error) {
	segment := make([]historyPoint, 0, maxRows)
	reason := "insufficient_history"
	start := len(rows) - maxRows
	if start < 0 {
		start = 0
	}
	for _, raw := range rows[start:] {
		row, ok := raw.(map[string]any)
		if !ok {
			return nil, errors.New("history row must be an object")
		}
		timestamp, timestampOK, err := capacityNumber(row["ts"])
		if err != nil {
			return nil, err
		}
		used, usedOK, err := capacityNumber(row["disk_used_gb"])
		if err != nil {
			return nil, err
		}
		total, totalOK, err := capacityNumber(row["disk_total_gb"])
		if err != nil {
			return nil, err
		}
		if !timestampOK || !usedOK || !totalOK || total <= 0 || used < 0 || used > total {
			segment = segment[:0]
			continue
		}
		if timestamp > now {
			segment = segment[:0]
			reason = "clock_changed"
			break
		}
		if timestamp < now-window {
			continue
		}
		if len(segment) != 0 {
			previous := segment[len(segment)-1]
			elapsed := timestamp - previous.timestamp
			if elapsed <= 0 || elapsed > maxGap || total != previous.total || used < previous.used {
				segment = segment[:0]
			}
		}
		segment = append(segment, historyPoint{row, timestamp, used, total})
	}
	result := map[string]any{
		"state": "insufficient_history", "reason": reason, "window_seconds": window,
		"sample_count": len(segment), "minimum_samples": minSamples, "from": nil, "to": nil,
		"growth_bytes_per_day": nil, "days_remaining": nil,
	}
	if len(segment) != 0 {
		result["from"] = segment[0].row["ts"]
		result["to"] = segment[len(segment)-1].row["ts"]
	}
	state, ok := filesystem["state"]
	if !ok {
		return nil, errors.New("filesystem requires state")
	}
	if state != "available" {
		result["state"] = "unavailable"
		result["reason"] = "filesystem_unavailable"
		return result, nil
	}
	disk, ok := filesystem["value"].(map[string]any)
	if !ok {
		return nil, errors.New("available filesystem value must be an object")
	}
	diskTotal, totalOK, err := capacityNumber(disk["total"])
	if err != nil {
		return nil, err
	}
	diskUsed, usedOK, err := capacityNumber(disk["used"])
	if err != nil {
		return nil, err
	}
	if !totalOK || !usedOK {
		return nil, errors.New("available filesystem value requires numeric total and used")
	}
	if len(segment) == 0 {
		return result, nil
	}
	last := segment[len(segment)-1]
	if diskTotal/gib != last.total {
		result["reason"] = "capacity_changed"
		return result, nil
	}
	if diskUsed/gib < last.used {
		result["reason"] = "usage_reset"
		return result, nil
	}
	span := last.timestamp - segment[0].timestamp
	if len(segment) < minSamples || span < (minSamples-1)*3600 {
		return result, nil
	}
	if now-last.timestamp > maxGap {
		result["reason"] = "stale_history"
		return result, nil
	}
	growth := (last.used - segment[0].used) * gib * 86400 / span
	if growth <= 0 {
		result["state"] = "no_growth"
		result["reason"] = "no_measured_growth"
		return result, nil
	}
	result["state"] = "estimated"
	result["reason"] = nil
	result["growth_bytes_per_day"] = growth
	result["days_remaining"] = (diskTotal - diskUsed) / growth
	return result, nil
}
