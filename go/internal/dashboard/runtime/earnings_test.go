package runtime

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"testing"
)

func TestEarningsUsesFirstPollInputs(t *testing.T) {
	generation := "old"
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodGet {
			_, _ = w.Write([]byte(`{"ok":true,"input":{"domain":` + domainFixture + `,
				"earnings":true,
				"snapshot":{"storage":{"generation":"old","payouts":{
				"monero":[{"ts":100,"amount_atomic":1000000000000}],"tari":[]}},
				"settings":{"now":100,"zone":"UTC","payout_confirm_enabled":true,
				"tari_payout_confirm_enabled":false}}}}`))
			generation = "new"
			return
		}
		var payload struct {
			Earnings bool `json:"earnings"`
			Sections map[string]struct {
				Confirmed struct {
					Total float64 `json:"xmr_all"`
					Last  float64 `json:"last_ts"`
				} `json:"confirmed"`
				TariConfirmed struct {
					Enabled bool `json:"enabled"`
				} `json:"tari_confirmed"`
			} `json:"sections"`
		}
		if err := json.NewDecoder(r.Body).Decode(&payload); err != nil {
			t.Error(err)
			w.WriteHeader(http.StatusInternalServerError)
			return
		}
		value, ok := payload.Sections["build_earnings"]
		if !ok || !payload.Earnings || generation != "new" || value.Confirmed.Total != 1 || value.Confirmed.Last != 100 || value.TariConfirmed.Enabled {
			t.Errorf("native first-generation earnings missing: %#v, generation=%q", value, generation)
		}
		_, _ = w.Write([]byte(`{"ok":true,"input":{"state":{}}}`))
	}))
	defer server.Close()
	target, _ := url.Parse(server.URL)
	if _, err := inputProvider(target)(context.Background(), "state", ""); err != nil {
		t.Fatal(err)
	}
}

func TestEarningsRejectsMissingPayoutInputs(t *testing.T) {
	for _, raw := range []string{`{}`, `null`, `[]`, `{"settings":{}}`, `{"settings":{"now":"bad"}}`} {
		if _, err := earningsSection(nil, nil, json.RawMessage(raw)); err == nil {
			t.Fatalf("accepted %s", raw)
		}
	}
}
