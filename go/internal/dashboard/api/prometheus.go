package api

import (
	"bytes"
	"encoding/json"
	"errors"
	"math"
	"strconv"
	"strings"
)

const PrometheusContentType = "text/plain; version=0.0.4; charset=utf-8"

type PrometheusInput struct {
	Metrics         json.RawMessage
	DiskPercent     json.RawMessage
	DBHealthy       bool
	RejectPct1H     json.RawMessage
	SharesAccepted  json.RawMessage
	SharesRejected  json.RawMessage
	PoolBlocksFound json.RawMessage
	SnapshotTS      float64
	Now             float64
}

type prometheusSample struct {
	name   string
	labels string
	path   string
	value  json.RawMessage
}

func RenderPrometheus(input PrometheusInput) (string, error) {
	metrics := map[string]json.RawMessage{}
	if err := json.Unmarshal(input.Metrics, &metrics); err != nil {
		return "", err
	}
	samples := []prometheusSample{
		{name: "pithead_hashrate_15m_hs", path: "total_h15"},
		{name: "pithead_p2pool_hashrate_hs", labels: `{window="1h"}`, path: "p2pool_1h"},
		{name: "pithead_p2pool_hashrate_hs", labels: `{window="24h"}`, path: "p2pool_24h"},
		{name: "pithead_xvb_routed_hashrate_hs", labels: `{window="1h"}`, path: "xvb_routed_1h"},
		{name: "pithead_xvb_routed_hashrate_hs", labels: `{window="24h"}`, path: "xvb_routed_24h"},
		{name: "pithead_xvb_credited_hashrate_hs", labels: `{window="1h"}`, path: "xvb_1h"},
		{name: "pithead_xvb_credited_hashrate_hs", labels: `{window="24h"}`, path: "xvb_24h"},
		{name: "pithead_stratum_hashrate_hs", labels: `{window="15m"}`, path: "stratum_h15"},
		{name: "pithead_stratum_hashrate_hs", labels: `{window="1h"}`, path: "stratum_h1h"},
		{name: "pithead_stratum_hashrate_hs", labels: `{window="24h"}`, path: "stratum_h24h"},
		{name: "pithead_workers_online", path: "workers_online"},
		{name: "pithead_workers_total", path: "workers_total"},
		{name: "pithead_shares_in_window", path: "shares_in_window"},
		{name: "pithead_pplns_window_blocks", path: "pplns_window"},
		{name: "pithead_pool_hashrate_hs", path: "pool_hashrate"},
		{name: "pithead_pool_difficulty", path: "pool_difficulty"},
		{name: "pithead_network_difficulty", path: "network_difficulty"},
		{name: "pithead_network_height", path: "network_height"},
		{name: "pithead_node_sync_percent", labels: `{chain="monero"}`, path: "monero.percent"},
		{name: "pithead_node_sync_percent", labels: `{chain="tari"}`, path: "tari.percent"},
		{name: "pithead_node_down", labels: `{chain="monero"}`, path: "monero.down"},
		{name: "pithead_node_down", labels: `{chain="tari"}`, path: "tari.down"},
		{name: "pithead_syncing", path: "global_syncing"},
		{name: "pithead_tari_mining", path: "tari_mining"},
		{name: "pithead_xvb_stale", path: "xvb_stale"},
		{name: "pithead_xvb_enabled", path: "xvb_enabled"},
		{name: "pithead_disk_used_percent", value: defaultRaw(input.DiskPercent)},
		{name: "pithead_db_healthy", value: boolRaw(input.DBHealthy)},
		{name: "pithead_luck_pct", path: "luck_pct"},
		{name: "pithead_expected_share_seconds", path: "expected_share_sec"},
		{name: "pithead_snapshot_age_seconds", value: floatRaw(math.Max(0, input.Now-input.SnapshotTS))},
	}
	if len(bytes.TrimSpace(input.RejectPct1H)) != 0 && !bytes.Equal(bytes.TrimSpace(input.RejectPct1H), []byte("null")) {
		samples = append(samples, prometheusSample{name: "pithead_share_reject_pct", labels: `{window="1h"}`, value: input.RejectPct1H})
	}
	counters := []prometheusSample{
		{name: "pithead_shares_accepted_total", value: defaultRaw(input.SharesAccepted)},
		{name: "pithead_shares_rejected_total", value: defaultRaw(input.SharesRejected)},
		{name: "pithead_pool_blocks_found_total", value: defaultRaw(input.PoolBlocksFound)},
	}
	var output strings.Builder
	if err := renderSamples(&output, samples, "gauge", metrics); err != nil {
		return "", err
	}
	if err := renderSamples(&output, counters, "counter", metrics); err != nil {
		return "", err
	}
	return output.String(), nil
}

func renderSamples(output *strings.Builder, samples []prometheusSample, metricType string, metrics map[string]json.RawMessage) error {
	typed := map[string]bool{}
	for _, sample := range samples {
		value := sample.value
		if sample.path != "" {
			var err error
			value, err = metricValue(metrics, sample.path)
			if err != nil {
				return err
			}
		}
		formatted, err := formatPrometheusValue(value)
		if err != nil {
			return err
		}
		if !typed[sample.name] {
			typed[sample.name] = true
			output.WriteString("# TYPE " + sample.name + " " + metricType + "\n")
		}
		output.WriteString(sample.name + sample.labels + " " + formatted + "\n")
	}
	return nil
}

func metricValue(metrics map[string]json.RawMessage, path string) (json.RawMessage, error) {
	parts := strings.Split(path, ".")
	value, ok := metrics[parts[0]]
	if !ok {
		return nil, errors.New("missing metric " + path)
	}
	if len(parts) == 1 {
		return value, nil
	}
	nested := map[string]json.RawMessage{}
	if err := json.Unmarshal(value, &nested); err != nil {
		return nil, err
	}
	value, ok = nested[parts[1]]
	if !ok {
		return nil, errors.New("missing metric " + path)
	}
	return value, nil
}

func formatPrometheusValue(raw json.RawMessage) (string, error) {
	raw = bytes.TrimSpace(raw)
	if bytes.Equal(raw, []byte("true")) {
		return "1", nil
	}
	if bytes.Equal(raw, []byte("false")) {
		return "0", nil
	}
	if len(raw) == 0 || !json.Valid(raw) || bytes.Equal(raw, []byte("null")) || raw[0] == '"' {
		return "", errors.New("invalid prometheus value")
	}
	value, err := strconv.ParseFloat(string(raw), 64)
	if err != nil || math.IsNaN(value) || math.IsInf(value, 0) {
		return "", errors.New("invalid prometheus value")
	}
	return string(raw), nil
}

func defaultRaw(raw json.RawMessage) json.RawMessage {
	if len(bytes.TrimSpace(raw)) == 0 {
		return json.RawMessage("0")
	}
	return raw
}

func boolRaw(value bool) json.RawMessage {
	if value {
		return json.RawMessage("true")
	}
	return json.RawMessage("false")
}

func floatRaw(value float64) json.RawMessage {
	format := byte('f')
	absolute := math.Abs(value)
	if absolute != 0 && (absolute < 0.0001 || absolute >= 1e16) {
		format = 'e'
	}
	formatted := strconv.FormatFloat(value, format, -1, 64)
	if !strings.ContainsAny(formatted, ".eE") {
		formatted += ".0"
	}
	return json.RawMessage(formatted)
}
