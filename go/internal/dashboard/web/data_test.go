package web

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"testing"
)

func TestNativeDataRoutes(t *testing.T) {
	for _, test := range []struct {
		path, operation, input, required, cache string
	}{
		{"/api/state?from=10&to=20", "state", `{"state":{"chart":null,"fixture":true},"chart":{"history":[],"shares":[],"range":"all","now":100}}`, `"fixture":true`, "no-cache"},
		{"/api/miner-connection", "miner-connection", `{"HostIP":"192.0.2.1","Bind":"0.0.0.0","Port":3333,"Password":"private-fixture"}`, `"password":"private-fixture"`, "no-store"},
		{"/api/xvb-standby", "xvb-standby", `{"stats":{"avg_1h":1234,"current_mode":"P2POOL"},"donation_level":"auto"}`, `"avg_1h":1234`, "no-cache"},
	} {
		t.Run(test.operation, func(t *testing.T) {
			calls := 0
			h := New(Options{
				Inputs: func(ctx context.Context, operation string, query string) (json.RawMessage, error) {
					calls++
					if operation != test.operation {
						t.Errorf("operation = %s", operation)
					}
					if operation == "state" && query != "from=10&to=20" {
						t.Error("state query was lost")
					}
					return json.RawMessage(test.input), nil
				},
				Reference: http.HandlerFunc(func(http.ResponseWriter, *http.Request) { t.Error("native route fell back") }),
			})
			for _, method := range []string{http.MethodGet, http.MethodHead} {
				response := httptest.NewRecorder()
				h.ServeHTTP(response, httptest.NewRequest(method, test.path, nil))
				if response.Code != http.StatusOK || response.Header().Get("Cache-Control") != test.cache || response.Header().Get("X-Frame-Options") != "DENY" {
					t.Fatalf("response = %d %#v", response.Code, response.Header())
				}
				if method == http.MethodGet {
					if !strings.Contains(response.Body.String(), test.required) || response.Header().Get("Content-Length") != strconv.Itoa(response.Body.Len()) {
						t.Fatalf("body = %s", response.Body.String())
					}
				} else if response.Body.Len() != 0 || response.Header().Get("Content-Length") == "" {
					t.Fatal("HEAD body or length changed")
				}
			}
			if calls != 2 {
				t.Fatalf("source calls = %d", calls)
			}
		})
	}
}

func TestDataFailuresAndCompatibility(t *testing.T) {
	for _, path := range []string{"/api/state", "/api/xvb-standby", "/metrics"} {
		h := New(Options{Inputs: func(context.Context, string, string) (json.RawMessage, error) {
			return nil, errors.New("private fixture detail")
		}})
		response := httptest.NewRecorder()
		h.ServeHTTP(response, httptest.NewRequest(http.MethodGet, path, nil))
		if response.Code != http.StatusInternalServerError || strings.Contains(response.Body.String(), "private") {
			t.Fatalf("failure leaked: %s", response.Body.String())
		}
		if response.Header().Get("Content-Length") != strconv.Itoa(response.Body.Len()) {
			t.Fatal("error length changed")
		}
	}
	for _, input := range []string{"missing", "invalid", "null"} {
		calls := 0
		h := New(Options{
			Inputs: func(context.Context, string, string) (json.RawMessage, error) {
				if input == "missing" {
					return nil, ErrInputsUnavailable
				}
				return json.RawMessage(input), nil
			},
			Reference: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				calls++
				w.WriteHeader(http.StatusAccepted)
			}),
		})
		response := httptest.NewRecorder()
		h.ServeHTTP(response, httptest.NewRequest(http.MethodGet, "/api/state", nil))
		if calls != 1 || response.Code != http.StatusAccepted {
			t.Fatal("compatibility fallback changed")
		}
	}
}
