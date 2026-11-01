package domain

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestRejectsNullTypedProtocolScalars(t *testing.T) {
	for _, field := range []string{
		"enable_xvb", "donation_level", "max_donation_fraction", "xvb_stats_stale_after_s",
		"monero_node_host", "local_monero_host", "monero_prune", "tari_mode", "monero_local",
	} {
		var input Input
		if err := json.Unmarshal([]byte(`{"config":{"`+field+`":null}}`), &input); err == nil {
			t.Errorf("null %s accepted", field)
		}
	}
	for _, value := range []string{`null`, `{"now":null}`, `{"config":null}`} {
		var input Input
		if err := json.Unmarshal([]byte(value), &input); err == nil {
			t.Errorf("invalid input %s accepted", value)
		}
	}
}

func TestDomainDecodePreservesNumbersAndNullableTari(t *testing.T) {
	var input Input
	if err := json.Unmarshal([]byte(`{"latest_data":{"total_live_h15":9007199254740993},"config":{"tari_local":null}}`), &input); err != nil {
		t.Fatal(err)
	}
	if input.LatestData["total_live_h15"] != json.Number("9007199254740993") || string(input.Config.TariLocal) != "null" {
		t.Fatalf("decoded = %#v", input)
	}
	encoded, err := json.Marshal(Input{})
	if err != nil || strings.Contains(string(encoded), "tari_local") || strings.Contains(string(encoded), "monero_local") {
		t.Fatalf("optional config = %s, %v", encoded, err)
	}
}

func TestNullHistoryRowRefusesNativeProcessing(t *testing.T) {
	input := baseInput()
	input.History = []map[string]any{nil}
	if _, err := Build(input); err == nil {
		t.Fatal("null history row accepted")
	}
}
