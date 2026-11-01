package infra

import (
	"bytes"
	"encoding/json"
	"reflect"
	"strings"
	"testing"
)

func request(operation string, args ...string) Request {
	raw := make([]json.RawMessage, len(args))
	for index := range args {
		raw[index] = json.RawMessage(args[index])
	}
	return Request{Operation: operation, Args: raw}
}

func TestBuildSystem(t *testing.T) {
	result, err := Build(request("build_system", `{"system":{"disk":{"percent":95,"used_gb":90,"total_gb":100,"percent_str":"95%"},"memory":{"percent":85,"used_gb":13,"total_gb":16,"percent_str":"85%"},"cpu_percent":"90.0%","load":"0.5 0.4 0.3","hugepages":["Enabled","status-ok","1555/3072"]}}`))
	if err != nil {
		t.Fatal(err)
	}
	resultMap := result.(map[string]any)
	if resultMap["cpu"].(map[string]any)["load"] != "1m: 0.5 5m: 0.4 15m: 0.3" || resultMap["disk"].(map[string]any)["fill"] != "critical" || resultMap["hugepages"].(map[string]any)["variant"] != "ok" {
		t.Fatalf("system = %#v", result)
	}
	empty, err := Build(request("build_system", `{}`))
	if err != nil || empty.(map[string]any)["disk"].(map[string]any)["unit"] != "GB" {
		t.Fatalf("empty system = %#v, %v", empty, err)
	}
}

func TestNumericStringsDoNotMaskReferenceFailures(t *testing.T) {
	for _, input := range []string{
		`{"system":{"disk":{"percent":"95"}}}`,
		`{"system":{"memory":{"percent":"85"}}}`,
	} {
		if _, err := Build(request("build_system", input)); err == nil {
			t.Errorf("invalid system input %s accepted", input)
		}
	}
	if _, err := arguments([]json.RawMessage{json.RawMessage(`{} {`)}, 1); err == nil {
		t.Fatal("malformed trailing infrastructure argument accepted")
	}
}

func TestBuildProxySummaryPreservesLargeIntegers(t *testing.T) {
	result, err := Build(request("build_proxy_summary", `{"proxy_summary":{"accepted":12345,"rejected":67,"invalid":2,"expired":1,"best":900719925474099312345}}`))
	if err != nil {
		t.Fatal(err)
	}
	got := result.(map[string]any)
	if got["accepted"] != "12,345" || got["best"] != "900,719,925,474,099,312,345" || got["reject_pct"] != "0.54%" || got["has_data"] != true {
		t.Fatalf("summary = %#v", got)
	}
}

func TestBuildProxySummaryUsesPythonFloatFormatting(t *testing.T) {
	result, err := Build(request("build_proxy_summary", `{"proxy_summary":{"accepted":1000000.0,"rejected":1.5,"expired":1e20,"best":12.9}}`))
	if err != nil {
		t.Fatal(err)
	}
	got := result.(map[string]any)
	if got["accepted"] != "1,000,000.0" || got["rejected"] != "1.5" || got["expired"] != "1e+20" || got["best"] != "12" {
		t.Fatalf("summary = %#v", got)
	}
}

func TestBuildProxySummaryRoundsDivisionBeforePercentage(t *testing.T) {
	result, err := Build(request("build_proxy_summary", `{"proxy_summary":{"accepted":19993,"rejected":7}}`))
	if err != nil {
		t.Fatal(err)
	}
	if got := result.(map[string]any)["reject_pct"]; got != "0.03%" {
		t.Fatalf("reject_pct = %q", got)
	}
}

func TestBuildTari(t *testing.T) {
	result, err := Build(request("build_tari", `{"tari":{"active":true,"connected":true,"status":"READY","reward":12.5,"height":42,"difficulty":1234567,"address":"TTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTT"}}`))
	if err != nil {
		t.Fatal(err)
	}
	got := result.(map[string]any)
	if got["status"] != "READY" || got["reward"] != "12.50 TARI" || got["diff"] != "1,234,567" || got["wallet_short"] != "TTTTTTTT...TTTTTTTT" {
		t.Fatalf("Tari = %#v", got)
	}
	unhealthy, err := Build(request("build_tari", `{"tari":{"active":true},"tari_sync":{"health":{"level":"red","reasons":["behind","stalled"],"advice":"restart"}}}`))
	if err != nil || unhealthy.(map[string]any)["status"] != "Not following the chain: behind; stalled. restart" {
		t.Fatalf("unhealthy Tari = %#v, %v", unhealthy, err)
	}
}

func TestBuildSyncAndMonero(t *testing.T) {
	metrics := `{"monero":{"done":true,"has_target":false,"percent":100,"current":10,"target":0,"remaining":0},"tari":{"done":false,"has_target":true,"percent":40,"current":40,"target":100,"remaining":60},"monero_mode":"Pruned","monero_local":false,"tari_local":true}`
	syncResult, err := Build(request("build_sync", metrics, `"85.0 GB"`))
	if err != nil {
		t.Fatal(err)
	}
	syncMap := syncResult.(map[string]any)
	if syncMap["monero"].(map[string]any)["state"] != "done" || syncMap["tari"].(map[string]any)["state"] != "syncing" || syncMap["monero"].(map[string]any)["local"] != false {
		t.Fatalf("sync = %#v", syncMap)
	}
	monero, err := Build(request("build_monero", `{"monero_sync":{"db_size":85000000000,"health":{"level":"red","peers_out":0,"peers_in":2,"advance_age_sec":125,"reasons":["0 outgoing peers"],"advice":"restart"}}}`, metrics))
	if err != nil {
		t.Fatal(err)
	}
	got := monero.(map[string]any)
	health := got["health"].(map[string]any)
	if got["db_size"] != "85.0 GB" || health["peers"] != "0 out / 2 in" || health["moved"] != "2m 5s ago" || health["status"] != "0 outgoing peers" || !strings.Contains(health["tooltip"].(string), "30 minutes") {
		t.Fatalf("monero = %#v", got)
	}
}

func TestHealthUnknownAndHugeDuration(t *testing.T) {
	unknown, err := health(map[string]any{"level": "unknown", "reachable": false})
	if err != nil || unknown["status"] != "Node not answering — see its down status" {
		t.Fatalf("unknown = %#v, %v", unknown, err)
	}
	formatted, err := duration(json.Number("900719925474099312345"))
	if err != nil || formatted != "10424999137431705d 0h 5m" {
		t.Fatalf("duration = %q, %v", formatted, err)
	}
}

func TestRunAndFailures(t *testing.T) {
	var output bytes.Buffer
	if err := Run(strings.NewReader(`{"operation":"build_proxy_summary","args":[{}]}`), &output); err != nil {
		t.Fatal(err)
	}
	var got map[string]any
	if err := json.Unmarshal(output.Bytes(), &got); err != nil || !reflect.DeepEqual(got["has_data"], false) {
		t.Fatalf("run = %s, %v", output.String(), err)
	}
	for _, input := range []string{
		`{"operation":"missing","args":[]}`,
		`{"operation":"build_sync","args":[{},""]}`,
		`{"operation":"build_system","args":[{}]} {}`,
	} {
		if err := Run(strings.NewReader(input), &bytes.Buffer{}); err == nil {
			t.Fatalf("Run(%q) succeeded", input)
		}
	}
}
