package api

import (
	"encoding/json"
	"testing"
)

func TestBuildXVBStandbyDefaultsAndMappings(t *testing.T) {
	got, err := BuildXVBStandby(json.RawMessage(`{"commanded_fraction":0.37,"avg_1h":1500.0,"current_mode":"XVB","last_update":null}`), "vip")
	if err != nil {
		t.Fatal(err)
	}
	if got["commanded_fraction"].(json.Number).String() != "0.37" || got["avg_1h"].(json.Number).String() != "1500.0" {
		t.Fatalf("numbers got %#v", got)
	}
	if got["avg_24h"] != 0.0 || got["mode"] != "XVB" || got["donation_level"] != "vip" || got["ts"] != nil {
		t.Fatalf("got %#v", got)
	}
}

func TestBuildXVBStandbyRejectsInvalidJSON(t *testing.T) {
	for _, raw := range []string{"", `null`, `[]`, `{`, `{"avg_1h":1 2}`} {
		if _, err := BuildXVBStandby(json.RawMessage(raw), "auto"); err == nil {
			t.Fatalf("accepted %q", raw)
		}
	}
}
