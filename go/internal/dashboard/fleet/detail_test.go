package fleet

import (
	"bytes"
	"encoding/json"
	"strings"
	"testing"
)

func TestConfigDriftCanonicalizesAndStripsCredentials(t *testing.T) {
	last := map[string]any{
		"DONATION": "1", "autotune": 1,
		"pools": []any{map[string]any{"url": "pool.example.com", "pass": "secret"}},
	}
	rig := map[string]any{
		"DONATION": 1, "autotune": "1",
		"pools": []any{map[string]any{"url": "pool.example.com", "pass": map[string]any{"__secret__": true}}},
	}
	value, err := Build(request(t, "config_drift", last, rig, false))
	if err != nil {
		t.Fatal(err)
	}
	if len(value.([]any)) != 0 {
		t.Fatalf("expected agreement: %#v", value)
	}
	value, err = Build(request(t, "config_drift", map[string]any{"DONATION": true}, map[string]any{"DONATION": 1}, false))
	if err != nil || len(value.([]any)) != 1 {
		t.Fatalf("boolean was laundered into a number: %#v %v", value, err)
	}
	value, err = Build(request(t, "config_drift", map[string]any{"pools": "1"}, map[string]any{"pools": 1}, false))
	if err != nil || len(value.([]any)) != 1 {
		t.Fatalf("raw string was laundered into a number: %#v %v", value, err)
	}
	value, err = Build(request(t, "config_drift", map[string]any{"DONATION": " 1_0 "}, map[string]any{"DONATION": 10}, false))
	if err != nil || len(value.([]any)) != 0 {
		t.Fatalf("Python numeric string was rejected: %#v %v", value, err)
	}
	value, err = Build(request(t, "config_drift", map[string]any{"autotune": json.Number("1e15")}, map[string]any{"autotune": "1000000000000000.0"}, false))
	if err != nil || len(value.([]any)) != 0 {
		t.Fatalf("Python float rendering changed: %#v %v", value, err)
	}
	value, err = Build(request(t, "config_drift", map[string]any{"pools": json.Number("9007199254740993")}, map[string]any{"pools": json.Number("9007199254740992.0")}, false))
	if err != nil || len(value.([]any)) != 1 {
		t.Fatalf("large integer equality lost precision: %#v %v", value, err)
	}
	value, err = Build(request(t, "config_drift", last, rig, true))
	if err != nil || value != nil {
		t.Fatalf("unsettled comparison must be withheld: %#v %v", value, err)
	}
}

func TestUnsettledApplyAndOrigins(t *testing.T) {
	value, err := Build(request(t, "_has_unsettled_apply", []any{
		map[string]any{"type": "upgrade", "status": "accepted"},
		map[string]any{"status": "running"},
		map[string]any{"status": "applied"},
	}))
	if err != nil || value != true {
		t.Fatalf("unexpected unsettled result: %#v %v", value, err)
	}
	meta := map[string]any{"source": "control"}
	cases := []struct {
		known  bool
		status any
		unread bool
		want   any
	}{
		{true, "applied", false, "here"}, {true, "failed", false, "reverted"},
		{true, "accepted", false, "unconfirmed"}, {false, nil, false, "elsewhere"},
		{true, "applied", true, "unread"},
	}
	for _, test := range cases {
		value, err = Build(request(t, "config_origin", meta, test.known, test.status, test.unread))
		if err != nil || value != test.want {
			t.Fatalf("origin %v: got %#v, %v", test, value, err)
		}
	}
}

func TestWorkerHashrateHistoryFiltersAndShapes(t *testing.T) {
	samples := []any{
		map[string]any{"ts": testNow - 7200, "h15": 1},
		map[string]any{"ts": testNow - 60, "h15": 1234},
	}
	markers := []any{
		map[string]any{"ts": testNow - 7200, "status": "failed"},
		map[string]any{"ts": testNow - 60, "status": "applied", "changes": map[string]any{"DONATION": 2}},
	}
	value, err := Build(request(t, "build_worker_hashrate_history", samples, markers, "1h", nil))
	if err != nil {
		t.Fatal(err)
	}
	history := resultObject(t, value)
	line := history["hashrate"].([]any)
	events := history["markers"].([]any)
	if len(line) != 1 || resultObject(t, line[0])["y"].(json.Number).String() != "1234" {
		t.Fatalf("unexpected hashrate: %#v", line)
	}
	if len(events) != 1 || resultObject(t, events[0])["type"] != "apply" || resultObject(t, events[0])["status"] != "applied" {
		t.Fatalf("unexpected markers: %#v", events)
	}
}

func TestBuildWorkerDetailAndEnvelope(t *testing.T) {
	envelope := map[string]any{
		"name": "rig1",
		"data": map[string]any{
			"timestamp": 123, "rigforge_release": map[string]any{"tag": "v1.11.2", "url": "https://example.com/release"},
			"workers": []any{map[string]any{
				"name": "rig1", "ip": "192.0.2.9", "status": "online", "h60": 5100,
				"rigforge": map[string]any{
					"generated_at": "2026-10-01T20:00:00Z", "version": "1.11.1",
					"config":      map[string]any{"DONATION": 2},
					"config_meta": map[string]any{"source": "control", "last_change_id": "cid"},
				},
			}},
		},
		"descriptor":         map[string]any{"name": "rig1", "host": "192.0.2.9"},
		"history":            []any{map[string]any{"ts": 1000, "status": "applied", "changes": map[string]any{"DONATION": 2}}},
		"hashrate_by_config": []any{map[string]any{"ts": 1000, "avg_h15": 1000, "min_h15": nil, "max_h15": 2000}},
		"matched":            map[string]any{"status": "applied"}, "last_applied": map[string]any{"DONATION": 2},
		"revision_drift": nil, "worker_history": []any{map[string]any{"ts": 1000, "h15": 1234}},
		"marker_history": []any{map[string]any{"ts": 1000, "status": "applied"}},
		"range_arg":      "all", "window": nil, "control_enabled": true,
		"writable_keys": []any{"watchdog", "DONATION"},
	}
	req := request(t, "build_worker_detail", envelope)
	req.Zone = "UTC"
	value, err := Build(req)
	if err != nil {
		t.Fatal(err)
	}
	detail := resultObject(t, value)
	if detail["found"] != true || detail["editable"] != true || detail["hashrate"] != "5.10 kH/s" || detail["config_origin"] != "here" {
		t.Fatalf("unexpected detail: %#v", detail)
	}
	if detail["writable_keys"].([]string)[0] != "DONATION" {
		t.Fatalf("writable keys not sorted: %#v", detail["writable_keys"])
	}
	byConfig := detail["hashrate_by_config"].([]any)
	if resultObject(t, byConfig[0])["avg_h15"] != "1.00 kH/s" || resultObject(t, byConfig[0])["applied_at"] != "00:16:40" {
		t.Fatalf("unexpected config history: %#v", byConfig)
	}

	encoded, err := json.Marshal(req)
	if err != nil {
		t.Fatal(err)
	}
	var rawOutput bytes.Buffer
	if err := Run(strings.NewReader(string(encoded)), &rawOutput); err != nil {
		t.Fatal(err)
	}
	var raw map[string]any
	if err := json.Unmarshal(rawOutput.Bytes(), &raw); err != nil {
		t.Fatal(err)
	}
	if raw["name"] != "rig1" || raw["ok"] != nil {
		t.Fatalf("default protocol was enveloped: %#v", raw)
	}

	req.Envelope = true
	encoded, err = json.Marshal(req)
	if err != nil {
		t.Fatal(err)
	}
	var output bytes.Buffer
	if err := Run(strings.NewReader(string(encoded)), &output); err != nil {
		t.Fatal(err)
	}
	var wrapped map[string]any
	if err := json.Unmarshal(output.Bytes(), &wrapped); err != nil {
		t.Fatal(err)
	}
	if wrapped["ok"] != true || wrapped["value"] == nil {
		t.Fatalf("unexpected envelope: %#v", wrapped)
	}
}

func TestWorkerDetailFailsClosedOnMissingCollectedInput(t *testing.T) {
	value := map[string]any{"name": "rig1"}
	if _, err := Build(request(t, "build_worker_detail", value)); err == nil {
		t.Fatal("expected incomplete detail envelope to fail")
	}
}
