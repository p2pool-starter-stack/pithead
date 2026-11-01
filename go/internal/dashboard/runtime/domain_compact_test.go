package runtime

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"testing"
)

func TestCompactDomainKeepsPreparedRowsOutOfPost(t *testing.T) {
	const compact = `{"latest_data":{"total_live_h15":17},"averages":{"p2pool_1h":12,"p2pool_24h":12,"p2pool_30d":12,"xvb_routed_1h":5,"xvb_routed_24h":5},"xvb_stats":{},"tiers":[],"config":{"enable_xvb":true,"donation_level":"auto","tari_mode":"off"},"now":100}`
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodGet {
			_, _ = w.Write([]byte(`{"ok":true,"input":{"domain":` + compact + `,"chart":{"history":[{"timestamp":100,"t":"x","v_p2pool":12,"v_xvb":5}],"shares":[],"duration":2592000}}}`))
			return
		}
		var payload map[string]json.RawMessage
		if err := json.NewDecoder(r.Body).Decode(&payload); err != nil {
			t.Error(err)
		}
		if payload["history"] != nil || payload["chart"] != nil || string(payload["compact_chart"]) != "true" {
			t.Errorf("post payload = %s", payload)
		}
		_, _ = w.Write([]byte(`{"ok":true,"input":{"state":{"syncing":false},"chart":{"range":"all","now":100}}}`))
	}))
	defer server.Close()
	target, _ := url.Parse(server.URL)
	raw, err := inputProvider(target)(context.Background(), "state", "")
	if err != nil {
		t.Fatal(err)
	}
	var result struct {
		Chart struct {
			History          []map[string]any `json:"history"`
			Shares           []map[string]any `json:"shares"`
			PreparedDuration float64          `json:"prepared_duration"`
		} `json:"chart"`
	}
	if err := json.Unmarshal(raw, &result); err != nil {
		t.Fatal(err)
	}
	if len(result.Chart.History) != 1 || len(result.Chart.Shares) != 0 || result.Chart.PreparedDuration != 2592000 {
		t.Fatalf("attached chart = %#v", result.Chart)
	}
}
