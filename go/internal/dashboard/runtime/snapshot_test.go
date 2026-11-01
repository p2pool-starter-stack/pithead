package runtime

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"testing"
)

func TestDomainStateForwardsFirstPhaseSnapshot(t *testing.T) {
	generation := "old"
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodGet {
			_, _ = w.Write([]byte(`{"ok":true,"input":{"domain":` + domainFixture +
				`,"snapshot":{"storage":{"generation":"` + generation + `"},"settings":{}}}}`))
			generation = "new"
			return
		}
		var payload struct {
			Snapshot struct {
				Storage map[string]any `json:"storage"`
			} `json:"snapshot"`
		}
		if err := json.NewDecoder(r.Body).Decode(&payload); err != nil {
			t.Fatal(err)
		}
		if payload.Snapshot.Storage["generation"] != "old" || generation != "new" {
			t.Fatalf("mixed snapshot: %#v live=%q", payload.Snapshot, generation)
		}
		_, _ = w.Write([]byte(`{"ok":true,"input":{"state":{}}}`))
	}))
	defer server.Close()
	target, _ := url.Parse(server.URL)
	if _, err := inputProvider(target)(context.Background(), "state", ""); err != nil {
		t.Fatal(err)
	}
}
