package cli

import (
	"bytes"
	"errors"
	"os"
	"path/filepath"
	"testing"
)

func TestConfigValidationProtocol(t *testing.T) {
	path := filepath.Join(t.TempDir(), "config.json")
	for _, fixture := range []struct {
		section string
		raw     string
		code    int
		text    string
	}{
		{"workers", `{}`, 0, ""},
		{"workers", `{"workers":{"list":[{"name":"rig"},{"name":"rig"}]}}`, 2, "workers.list has duplicate names (rig) — the first-declared entry wins; a renamed rig needs its config entry updated.\n"},
		{"webhooks", `{"notifications":{"webhooks":false}}`, 1, "notifications.webhooks must be an array of URL strings.\n"},
		{"energy", `{"dashboard":{"energy":{"price_feed":null}}}`, 1, "dashboard.energy.price_feed must be true or false (fetch live XMR/XTM prices from CoinGecko over Tor; default false, no clearnet egress).\n"},
		{"unknown", `{}`, 125, ""},
		{"workers", `{`, 125, ""},
	} {
		t.Run(fixture.section+"/"+fixture.raw, func(t *testing.T) {
			if err := os.WriteFile(path, []byte(fixture.raw), 0o600); err != nil {
				t.Fatal(err)
			}
			var output bytes.Buffer
			err := configValidation([]string{fixture.section, path}, &output)
			code := 0
			if err != nil {
				var status *ExitError
				if !errors.As(err, &status) {
					t.Fatal(err)
				}
				code = status.Code
			}
			if code != fixture.code || output.String() != fixture.text {
				t.Fatalf("got status %d / %q, want %d / %q", code, output.String(), fixture.code, fixture.text)
			}
		})
	}
}

func TestConfigValidationUnsupportedArguments(t *testing.T) {
	for _, args := range [][]string{nil, {"workers"}, {"workers", "-"}, {"energy", filepath.Join(t.TempDir(), "missing")}, {"energy", "-", "extra"}} {
		var output bytes.Buffer
		err := configValidation(args, &output)
		var status *ExitError
		if !errors.As(err, &status) || status.Code != 125 || output.Len() != 0 {
			t.Fatalf("args %q: got %v and %q", args, err, output.String())
		}
	}
}
