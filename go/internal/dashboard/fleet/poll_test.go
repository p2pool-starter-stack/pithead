package fleet

import (
	"bytes"
	"encoding/json"
	"fmt"
	"strings"
	"testing"
	"time"
)

func pollRequest(t *testing.T, operation string, now float64, args ...string) Request {
	t.Helper()
	raw := make([]json.RawMessage, len(args))
	for index := range args {
		raw[index] = json.RawMessage(args[index])
	}
	return Request{Operation: operation, Args: raw, Now: now}
}

func pollBuild(t *testing.T, operation string, now float64, args ...string) any {
	t.Helper()
	result, err := Build(pollRequest(t, operation, now, args...))
	if err != nil {
		t.Fatal(err)
	}
	return result
}

func pollBuildValues(t *testing.T, operation string, now float64, args ...any) any {
	t.Helper()
	raw := make([]json.RawMessage, len(args))
	for index := range args {
		encoded, err := json.Marshal(args[index])
		if err != nil {
			t.Fatal(err)
		}
		raw[index] = encoded
	}
	result, err := Build(Request{Operation: operation, Args: raw, Now: now})
	if err != nil {
		t.Fatal(err)
	}
	return result
}

func TestPollNormalizeAndMissingWorkers(t *testing.T) {
	result := pollBuild(t, "poll_normalize_proxy_workers", 20,
		`{"workers":[["rig","192.0.2.4",0,3,0,0,0,19000,9007199254740993,2,3,4,5],["short"],{"id":"old","hashrate":[1,2]}]}`,
		`5`)
	workers := result.([]any)
	if len(workers) != 2 {
		t.Fatalf("workers = %#v", workers)
	}
	first := workers[0].(map[string]any)
	if first["status"] != "online" || first["h10"].(json.Number).String() != "9007199254740993000" {
		t.Fatalf("first = %#v", first)
	}
	legacy := workers[1].(map[string]any)
	if legacy["h1h"].(json.Number).String() != "2" {
		t.Fatalf("legacy = %#v", legacy)
	}

	request := pollRequest(t, "poll_normalize_proxy_workers", 0, `{"summary":{}}`, `5`)
	request.Envelope = true
	var output bytes.Buffer
	if err := Run(strings.NewReader(mustJSON(t, request)), &output); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(output.String(), `"kind":"ValueError"`) {
		t.Fatalf("output = %s", output.String())
	}
}

func TestPollSummaryAndCounters(t *testing.T) {
	parsed := pollBuild(t, "poll_parse_proxy_summary", 0,
		`{"results":{"accepted":4,"rejected":1,"invalid":0,"expired":2,"best":[99,2]}}`).(map[string]any)
	if parsed["best"].(json.Number).String() != "99" {
		t.Fatalf("parsed = %#v", parsed)
	}
	merged := pollBuild(t, "poll_merge_proxy_summary", 0, `{"accepted":7}`, `[]`).(map[string]any)
	if merged["adopt"] != false || merged["summary"] != nil {
		t.Fatalf("merged = %#v", merged)
	}
	deltas := pollBuild(t, "poll_summary_deltas", 0,
		`{"accepted":9007199254740993,"rejected":2,"invalid":0,"expired":0}`,
		`{"accepted":9007199254740995,"rejected":3,"invalid":0,"expired":0}`).([]any)[0].(map[string]any)
	if deltas["accepted"].(json.Number).String() != "2" {
		t.Fatalf("deltas = %#v", deltas)
	}
	shares := pollBuild(t, "poll_shares_to_record", 0, `9007199254740993`, `9007199254740998`).([]any)
	if shares[0].(json.Number).String() != "5" {
		t.Fatalf("shares = %#v", shares)
	}
	mixedShares := pollBuild(t, "poll_shares_to_record", 0, `100000000000000000000000`, `1e23`).([]any)
	if mixedShares[0].(json.Number).String() != "0" || mixedShares[1].(json.Number).String() != "1e23" {
		t.Fatalf("mixed shares = %#v", mixedShares)
	}
	mixedDeltas := pollBuild(t, "poll_summary_deltas", 0,
		`{"accepted":100000000000000000000000,"rejected":0,"invalid":0,"expired":0}`,
		`{"accepted":1e23,"rejected":1,"invalid":0,"expired":0}`).([]any)
	if mixedDeltas[0] != nil {
		t.Fatalf("mixed deltas = %#v", mixedDeltas)
	}
}

func TestPollDirectPatchesAndAggregates(t *testing.T) {
	patches := pollBuild(t, "poll_merge_direct_stats", 0,
		`[{"name":"a","uptime":2,"nested":{"kept":true}},{"name":"ignored","uptime":3}]`,
		`[{"api_ok":true,"adopted":1,"kind":"proxy","hashrate":{"total":[2,3,4]}}]`,
		`3333`, `[{"version":"1"}]`).([]any)
	if len(patches) != 1 {
		t.Fatalf("patches = %#v", patches)
	}
	patch := patches[0].(map[string]any)
	if _, ok := patch["nested"]; ok || patch["h15"].(json.Number).String() != "4000" || patch["adopted"] != true {
		t.Fatalf("patch = %#v", patch)
	}
	aggregate := pollBuild(t, "poll_aggregate_hashrate", 0,
		`[{"status":"online","h15":0,"h60":9007199254740993,"h10":2},{"status":"offline","h15":99,"h10":99}]`).([]any)
	if aggregate[0].(json.Number).String() != "9007199254740993" || aggregate[1].(json.Number).String() != "2" {
		t.Fatalf("aggregate = %#v", aggregate)
	}
	floatAggregate := pollBuild(t, "poll_aggregate_hashrate", 0,
		`[{"status":"online","h15":0.1,"h10":0.1},{"status":"online","h15":0.2,"h10":0.2}]`).([]any)
	left, right := 0.1, 0.2
	if floatAggregate[0].(float64) != left+right {
		t.Fatalf("float aggregate = %#v", floatAggregate)
	}
}

func TestPollLifecycleUptimeDoesNotOverflowInt64(t *testing.T) {
	result := pollBuild(t, "poll_lifecycle", 1e100,
		`[{"name":"up","status":"online","uptime":0}]`,
		`[["up",{"connected_since":0,"last_active":0}]]`, `50`).(map[string]any)
	uptime := result["patches"].([]any)[0].(map[string]any)["uptime"].(json.Number).String()
	if len(uptime) < 50 || strings.HasPrefix(uptime, "-") {
		t.Fatalf("uptime = %s", uptime)
	}
}

func TestPollLifecycleAndProbeAlignment(t *testing.T) {
	lifecycle := pollBuild(t, "poll_lifecycle", 110,
		`[{"name":"up","status":"online","uptime":0},{"name":"up","status":"online","uptime":0},{"name":null,"status":"offline","uptime":0},{"name":"","status":"offline","uptime":0}]`,
		`[["up",{"connected_since":100,"last_active":100}],[null,{"connected_since":null,"last_active":10}],["",{"connected_since":null,"last_active":10}]]`,
		`50`).(map[string]any)
	patches := lifecycle["patches"].([]any)
	if patches[0].(map[string]any)["uptime"].(json.Number).String() != "10" || patches[1].(map[string]any)["uptime"].(json.Number).String() != "10" || len(lifecycle["live_indices"].([]any)) != 2 || len(lifecycle["state"].([]any)) != 3 {
		t.Fatalf("lifecycle = %#v", lifecycle)
	}
	plan := pollBuild(t, "poll_probe_plan", 0,
		`[{"name":"up","ip":"192.0.2.1","status":"online"},{"name":"held","ip":"192.0.2.2","status":"offline"},{"name":"gone","ip":"192.0.2.3","status":"offline"}]`,
		`[["held","192.0.2.2"]]`).([]any)
	if plan[0] != true || plan[1] != true || plan[2] != false {
		t.Fatalf("plan = %#v", plan)
	}
	complete := pollBuild(t, "poll_probe_complete", 0,
		`[{"name":"up","ip":"192.0.2.1"},{"name":"held","ip":"192.0.2.2"},{"name":"gone","ip":"192.0.2.3"}]`,
		`[true,true,false]`, `[{"api_ok":false},{"api_ok":true}]`).(map[string]any)
	indices := complete["result_indices"].([]any)
	if indices[0].(json.Number).String() != "0" || indices[1].(json.Number).String() != "1" || indices[2] != nil {
		t.Fatalf("complete = %#v", complete)
	}
	answered := complete["answered"].([]any)
	if len(answered) != 1 || answered[0].([]any)[0] != "held" {
		t.Fatalf("answered = %#v", answered)
	}
}

func TestPollStateLookupsScaleLinearly(t *testing.T) {
	const count = 12000
	workers := make([]any, 0, count+1)
	records := make([]any, 0, count)
	answered := make([]any, 0, count)
	for index := 0; index < count; index++ {
		name := fmt.Sprintf("rig-%d", index)
		ip := fmt.Sprintf("rig-%d.example.com", index)
		workers = append(workers, map[string]any{"name": name, "ip": ip, "status": "offline", "uptime": 0})
		records = append(records, []any{name, map[string]any{"connected_since": nil, "last_active": 1}})
		answered = append(answered, []any{name, ip})
	}
	workers = append(workers, map[string]any{"name": "rig-0", "ip": "duplicate.example.com", "status": "offline", "uptime": 0})
	started := time.Now()
	lifecycle := pollBuildValues(t, "poll_lifecycle", 2, workers, records, 10).(map[string]any)
	if len(lifecycle["state"].([]any)) != count || len(lifecycle["live_indices"].([]any)) != count+1 {
		t.Fatalf("lifecycle shape = %#v %#v", len(lifecycle["state"].([]any)), len(lifecycle["live_indices"].([]any)))
	}
	plan := pollBuildValues(t, "poll_probe_plan", 0, workers[:count], answered).([]any)
	if len(plan) != count || plan[0] != true || plan[count-1] != true {
		t.Fatalf("probe plan shape = %#v", len(plan))
	}
	if elapsed := time.Since(started); elapsed > 5*time.Second {
		t.Fatalf("large state transforms took %s", elapsed)
	}
}

func TestPollNonfiniteTransport(t *testing.T) {
	marker := "poll-special"
	request := pollRequest(t, "poll_aggregate_hashrate", 0,
		`[{"status":"online","h15":{"poll-special":"inf"},"h10":1}]`)
	request.Envelope = true
	request.NonfiniteMarker = marker
	var output bytes.Buffer
	if err := Run(strings.NewReader(mustJSON(t, request)), &output); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(output.String(), `"poll-special":"inf"`) {
		t.Fatalf("output = %s", output.String())
	}
}

func mustJSON(t *testing.T, value any) string {
	t.Helper()
	encoded, err := json.Marshal(value)
	if err != nil {
		t.Fatal(err)
	}
	return string(encoded)
}
