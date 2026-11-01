package runtime

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"net/url"
	"reflect"
	"testing"

	dashboardweb "github.com/p2pool-starter-stack/pithead/go/internal/dashboard/web"
)

const domainFixture = `{"latest_data":{"total_live_h15":17},"history":[{"timestamp":100,"v_p2pool":12,"v_xvb":5}],"xvb_stats":{},"tiers":[],"config":{"enable_xvb":true,"donation_level":"auto","tari_mode":"off"},"now":100}`

func TestNativeDomainStateHandoff(t *testing.T) {
	query := "range=1h;extra=1&avg=1m&avg=24h"
	var methods []string
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		methods = append(methods, r.Method)
		if r.URL.Path != "/_go/state" || r.URL.RawQuery != query || r.Header.Get("Authorization") != "" {
			t.Errorf("private request = %s %s", r.Method, r.URL.RequestURI())
		}
		if r.Method == http.MethodGet {
			_, _ = w.Write([]byte(`{"ok":true,"input":{"domain":` + domainFixture + `}}`))
			return
		}
		if r.Header.Get("Content-Type") != "application/json" {
			t.Errorf("content type = %q", r.Header.Get("Content-Type"))
		}
		var payload struct {
			LatestData map[string]any   `json:"latest_data"`
			History    []map[string]any `json:"history"`
			Metrics    map[string]any   `json:"metrics"`
		}
		if err := json.NewDecoder(r.Body).Decode(&payload); err != nil {
			t.Error(err)
		}
		if payload.Metrics["p2pool_1h"] != float64(12) || payload.Metrics["xvb_routed_1h"] != float64(5) || payload.LatestData["total_live_h15"] != float64(17) || len(payload.History) != 1 {
			t.Errorf("state handoff = %#v", payload)
		}
		_, _ = w.Write([]byte(`{"ok":true,"input":{"state":{"syncing":false},"chart":{}}}`))
	}))
	defer server.Close()
	target, _ := url.Parse(server.URL)
	raw, err := inputProvider(target)(context.Background(), "state", query)
	if err != nil || string(raw) != `{"state":{"syncing":false},"chart":{}}` || !reflect.DeepEqual(methods, []string{"GET", "POST"}) {
		t.Fatalf("handoff = %s, %v, %v", raw, err, methods)
	}
}

func TestNativePrometheusDomainInputs(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet || r.URL.Path != "/_go/metrics" {
			t.Errorf("request = %s %s", r.Method, r.URL.Path)
		}
		_, _ = w.Write([]byte(`{"ok":true,"input":{"domain":` + domainFixture + `,"share_stats":[{"ts":99,"accepted":3,"rejected":1}],"DBHealthy":true}}`))
	}))
	defer server.Close()
	target, _ := url.Parse(server.URL)
	raw, err := inputProvider(target)(context.Background(), "metrics", "")
	if err != nil {
		t.Fatal(err)
	}
	var result struct {
		Metrics     map[string]any
		RejectPct1H float64
		DBHealthy   bool
		Domain      any
		ShareStats  any `json:"share_stats"`
	}
	if err := json.Unmarshal(raw, &result); err != nil {
		t.Fatal(err)
	}
	if result.Metrics["p2pool_1h"] != float64(12) || result.RejectPct1H != 25 || !result.DBHealthy || result.Domain != nil || result.ShareStats != nil {
		t.Fatalf("metrics = %s", raw)
	}
}

func TestDomainProtocolFailureBoundaries(t *testing.T) {
	for _, test := range []struct {
		name, input string
		missing     bool
		postStatus  int
	}{
		{"invalid-domain", `{"domain":{"history":[{"timestamp":"invalid"}]}}`, true, 0},
		{"null-config", `{"domain":{"config":{"max_donation_fraction":null}}}`, true, 0},
		{"invalid-shares", `{"domain":` + domainFixture + `,"share_stats":{}}`, true, 0},
		{"post-error", `{"domain":` + domainFixture + `}`, false, 500},
		{"old-post", `{"domain":` + domainFixture + `}`, true, 404},
	} {
		t.Run(test.name, func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.Method == http.MethodPost {
					w.WriteHeader(test.postStatus)
					return
				}
				_, _ = w.Write([]byte(`{"ok":true,"input":` + test.input + `}`))
			}))
			defer server.Close()
			target, _ := url.Parse(server.URL)
			operation := "state"
			if test.name == "invalid-shares" {
				operation = "metrics"
			}
			_, err := inputProvider(target)(context.Background(), operation, "")
			if err == nil || errors.Is(err, dashboardweb.ErrInputsUnavailable) != test.missing {
				t.Fatalf("error = %v, want missing=%v", err, test.missing)
			}
		})
	}
}
