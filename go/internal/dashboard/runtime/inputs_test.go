package runtime

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"net/url"
	"testing"

	dashboardweb "github.com/p2pool-starter-stack/pithead/go/internal/dashboard/web"
)

func TestInputProvider(t *testing.T) {
	for _, test := range []struct {
		name, body string
		status     int
		missing    bool
		failed     bool
	}{
		{"valid", `{"ok":true,"input":{"fixture":1}}`, 200, false, false},
		{"old-backend", "404: Not Found", 404, true, true},
		{"sentinel", "reference", 299, true, true},
		{"error", `{"ok":false}`, 500, false, true},
		{"malformed", `{"private":`, 200, true, true},
		{"non-finite", `{"ok":true,"input":{"fixture":NaN}}`, 200, true, true},
		{"redirect", "", 302, true, true},
	} {
		t.Run(test.name, func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.URL.RequestURI() != "/_go/state?range=1h" || r.Method != http.MethodGet {
					t.Errorf("input request = %s %s", r.Method, r.URL.RequestURI())
				}
				if test.status == 302 {
					w.Header().Set("Location", "/must-not-follow")
				}
				w.WriteHeader(test.status)
				_, _ = w.Write([]byte(test.body))
			}))
			defer server.Close()
			target, _ := url.Parse(server.URL)
			value, err := inputProvider(target)(context.Background(), "state", "range=1h")
			if (err != nil) != test.failed || errors.Is(err, dashboardweb.ErrInputsUnavailable) != test.missing {
				t.Fatalf("result %s, %v", value, err)
			}
			if !test.failed && string(value) != `{"fixture":1}` {
				t.Fatalf("input = %s", value)
			}
		})
	}
}

func TestInputProviderPreservesRawQuery(t *testing.T) {
	query := "range=1h;extra=1&avg=1m&avg=24h"
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.RawQuery != query {
			t.Errorf("query = %q", r.URL.RawQuery)
		}
		_, _ = w.Write([]byte(`{"ok":true,"input":{}}`))
	}))
	defer server.Close()
	target, _ := url.Parse(server.URL)
	if _, err := inputProvider(target)(context.Background(), "state", query); err != nil {
		t.Fatal(err)
	}
}
