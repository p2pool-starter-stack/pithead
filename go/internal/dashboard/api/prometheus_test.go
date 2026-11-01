package api

import (
	"encoding/json"
	"strings"
	"testing"
)

const metricsFixture = `{
"total_h15":12500.0,"p2pool_1h":1500.0,"p2pool_24h":1400.5,
"xvb_1h":900.0,"xvb_24h":800.0,"xvb_routed_1h":950.0,"xvb_routed_24h":850.0,
"stratum_h15":12000.0,"stratum_h1h":11000.0,"stratum_h24h":10000.0,
"workers_online":3,"workers_total":4,"shares_in_window":2,"pplns_window":2160,
"pool_hashrate":21000000.0,"pool_difficulty":1000000.0,"network_difficulty":413245678901.0,"network_height":3200000,
"monero":{"percent":100,"down":true},"tari":{"percent":42,"down":false},
"global_syncing":false,"tari_mining":true,"xvb_stale":false,"xvb_enabled":true,
"luck_pct":105.5,"expected_share_sec":3600.0
}`

func TestRenderPrometheusExactValues(t *testing.T) {
	body, err := RenderPrometheus(PrometheusInput{
		Metrics: json.RawMessage(metricsFixture), DiskPercent: json.RawMessage("63.2"), DBHealthy: true,
		RejectPct1H: json.RawMessage("2.5"), SharesAccepted: json.RawMessage("12345"),
		SharesRejected: json.RawMessage("67"), PoolBlocksFound: json.RawMessage("9"),
		SnapshotTS: 1000, Now: 1030,
	})
	if err != nil {
		t.Fatal(err)
	}
	for _, line := range []string{
		"pithead_hashrate_15m_hs 12500.0",
		`pithead_p2pool_hashrate_hs{window="24h"} 1400.5`,
		"pithead_network_difficulty 413245678901.0",
		`pithead_node_down{chain="monero"} 1`,
		"pithead_db_healthy 1",
		"pithead_snapshot_age_seconds 30.0",
		`pithead_share_reject_pct{window="1h"} 2.5`,
		"# TYPE pithead_shares_accepted_total counter",
		"pithead_shares_accepted_total 12345",
	} {
		if !strings.Contains(body, line+"\n") {
			t.Fatalf("missing %q in:\n%s", line, body)
		}
	}
	if strings.Count(body, "# TYPE pithead_p2pool_hashrate_hs gauge\n") != 1 || !strings.HasSuffix(body, "\n") {
		t.Fatalf("invalid family headers or ending:\n%s", body)
	}
}

func TestRenderPrometheusOmissionsDefaultsAndClockSkew(t *testing.T) {
	body, err := RenderPrometheus(PrometheusInput{Metrics: json.RawMessage(metricsFixture), RejectPct1H: json.RawMessage("null"), SnapshotTS: 20, Now: 10})
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(body, "pithead_share_reject_pct") || !strings.Contains(body, "pithead_snapshot_age_seconds 0.0\n") {
		t.Fatalf("got:\n%s", body)
	}
	for _, line := range []string{"pithead_disk_used_percent 0", "pithead_shares_accepted_total 0", "pithead_db_healthy 0"} {
		if !strings.Contains(body, line+"\n") {
			t.Fatalf("missing %q", line)
		}
	}
}

func TestRenderPrometheusPythonFloatStyleForAge(t *testing.T) {
	for _, test := range []struct {
		now  float64
		want string
	}{
		{1700000000, "1700000000.0"},
		{0.000001, "1e-06"},
	} {
		body, err := RenderPrometheus(PrometheusInput{Metrics: json.RawMessage(metricsFixture), Now: test.now})
		if err != nil {
			t.Fatal(err)
		}
		if !strings.Contains(body, "pithead_snapshot_age_seconds "+test.want+"\n") {
			t.Fatalf("missing age %q", test.want)
		}
	}
	body, err := RenderPrometheus(PrometheusInput{Metrics: json.RawMessage(metricsFixture), DiskPercent: json.RawMessage("1e-07")})
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(body, "pithead_disk_used_percent 1e-07\n") {
		t.Fatal("raw Python float spelling changed")
	}
}

func TestRenderPrometheusRejectsMissingAndInvalidValues(t *testing.T) {
	if _, err := RenderPrometheus(PrometheusInput{Metrics: json.RawMessage(`{}`)}); err == nil {
		t.Fatal("accepted missing metrics")
	}
	invalid := strings.Replace(metricsFixture, `"total_h15":12500.0`, `"total_h15":null`, 1)
	if _, err := RenderPrometheus(PrometheusInput{Metrics: json.RawMessage(invalid)}); err == nil {
		t.Fatal("accepted null metric")
	}
	for _, raw := range []string{"NaN", "Infinity", "-Infinity"} {
		if _, err := RenderPrometheus(PrometheusInput{Metrics: json.RawMessage(metricsFixture), DiskPercent: json.RawMessage(raw)}); err == nil {
			t.Fatalf("accepted non-JSON value %q", raw)
		}
	}
}
