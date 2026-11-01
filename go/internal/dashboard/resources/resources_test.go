package resources

import (
	"bytes"
	"encoding/json"
	"strings"
	"testing"
)

const testNow = 1800000000

func raw(value string) json.RawMessage {
	return json.RawMessage(value)
}

func samples() string {
	return `{
		"cpu":{"sampled_at":1800000000,"value":0},
		"load":{"sampled_at":1800000000,"value":[0,0.5,1.5]},
		"memory":{"sampled_at":1800000000,"value":{"total":4294967296,"used":1073741824,"available":3221225472}},
		"filesystem":{"sampled_at":1800000000,"value":{"total":536870912000,"used":132070244352}},
		"hugepages":{"sampled_at":1800000000,"value":{"total":0,"used":0,"free":0}}
	}`
}

func history(count int, interval int, used float64, step float64, total float64) string {
	rows := make([]map[string]any, count)
	for i := range rows {
		rows[i] = map[string]any{
			"ts": testNow - (count-i-1)*interval, "disk_used_gb": used + float64(i)*step,
			"disk_total_gb": total,
		}
	}
	encoded, _ := json.Marshal(rows)
	return string(encoded)
}

func TestBuildHostResources(t *testing.T) {
	result, err := Build(Request{
		Operation: "build_host_resources", Args: []json.RawMessage{raw(samples()), raw(history(24, 3600, 100, 1, 500))},
		Now: testNow + 10, MaxAge: 90,
	})
	if err != nil {
		t.Fatal(err)
	}
	resources := result.(map[string]any)
	if resources["swap"].(map[string]any)["unit"] != "bytes" {
		t.Fatal("unsupported swap resource lost its unit")
	}
	cpu := resources["cpu"].(map[string]any)
	if cpu["state"] != "available" || cpu["age_seconds"] != float64(10) || cpu["value"].(json.Number).String() != "0" {
		t.Fatalf("unexpected CPU resource: %#v", cpu)
	}
	unsupported := resources["temperature"].(map[string]any)
	if unsupported["state"] != "unavailable" || unsupported["reason"] != "unsupported" {
		t.Fatalf("unexpected unsupported resource: %#v", unsupported)
	}
	outlook := resources["capacity_outlook"].(map[string]any)
	if outlook["state"] != "estimated" || outlook["sample_count"] != 24 {
		t.Fatalf("unexpected capacity outlook: %#v", outlook)
	}
	if outlook["growth_bytes_per_day"] != float64(24*1024*1024*1024) {
		t.Fatalf("unexpected growth: %#v", outlook["growth_bytes_per_day"])
	}
}

func TestInvalidSamplesBecomeUnavailable(t *testing.T) {
	data := `{
		"cpu":{"sampled_at":1800000000,"value":{"nonfinite":"nan"}},
		"load":{"sampled_at":1800000000,"value":[0,true,1]},
		"memory":{"sampled_at":1800000000,"value":{"total":10,"used":8,"available":8}},
		"filesystem":{"sampled_at":1800000000,"value":{"total":0,"used":0}},
		"hugepages":{"sampled_at":1800000000,"value":{"total":10,"used":5}}
	}`
	result, err := Build(Request{Operation: "build_host_resources", Args: []json.RawMessage{raw(data), raw(`[]`)}, Now: testNow})
	if err != nil {
		t.Fatal(err)
	}
	resources := result.(map[string]any)
	for _, name := range []string{"cpu", "load", "memory", "filesystem", "hugepages"} {
		resource := resources[name].(map[string]any)
		if resource["state"] != "unavailable" || resource["reason"] != "invalid_sample" || resource["value"] != nil {
			t.Fatalf("unexpected %s resource: %#v", name, resource)
		}
	}
}

func TestLargeIntegerResourceValidationIsExact(t *testing.T) {
	data := `{
		"memory":{"sampled_at":1800000000,"value":{"total":9007199254740992,"used":9007199254740991,"available":2}}
	}`
	result, err := Build(Request{Operation: "build_host_resources", Args: []json.RawMessage{raw(data), raw(`[]`)}, Now: testNow})
	if err != nil {
		t.Fatal(err)
	}
	memory := result.(map[string]any)["memory"].(map[string]any)
	if memory["reason"] != "invalid_sample" || memory["value"] != nil {
		t.Fatalf("accepted rounded integer sum: %#v", memory)
	}

	data = `{
		"memory":{"sampled_at":1800000000,"value":{"total":9007199254740993,"used":9007199254740992,"available":1}}
	}`
	result, err = Build(Request{Operation: "build_host_resources", Args: []json.RawMessage{raw(data), raw(`[]`)}, Now: testNow})
	if err != nil {
		t.Fatal(err)
	}
	memory = result.(map[string]any)["memory"].(map[string]any)
	if memory["state"] != "available" {
		t.Fatalf("rejected exact integer sum: %#v", memory)
	}
}

func TestAgeBoundaryAndClockChange(t *testing.T) {
	for _, test := range []struct {
		now    float64
		state  string
		reason any
	}{
		{testNow + 90, "available", nil},
		{testNow + 91, "unavailable", "stale"},
		{testNow - 1, "unavailable", "clock_changed"},
	} {
		result, err := Build(Request{Operation: "build_host_resources", Args: []json.RawMessage{raw(samples()), raw(`[]`), raw(`null`)}, Now: test.now, MaxAge: 90})
		if err != nil {
			t.Fatal(err)
		}
		cpu := result.(map[string]any)["cpu"].(map[string]any)
		if cpu["state"] != test.state || cpu["reason"] != test.reason {
			t.Fatalf("now %v: %#v", test.now, cpu)
		}
	}
}

func TestCapacitySegmentsAndBound(t *testing.T) {
	rows := history(10000, 3600, 0, 0.01, 500)
	filesystem := `{"state":"available","value":{"total":536870912000,"used":107374182400}}`
	result, err := Build(Request{Operation: "capacity_outlook", Args: []json.RawMessage{raw(rows), raw(filesystem), raw(`1800000000`)}})
	if err != nil {
		t.Fatal(err)
	}
	outlook := result.(map[string]any)
	if outlook["state"] != "estimated" || outlook["sample_count"] != 169 {
		t.Fatalf("unexpected bounded outlook: %#v", outlook)
	}

	future := `[{"ts":1800000001,"disk_used_gb":100,"disk_total_gb":500}]`
	result, err = Build(Request{Operation: "capacity_outlook", Args: []json.RawMessage{raw(future), raw(filesystem), raw(`1800000000`)}})
	if err != nil {
		t.Fatal(err)
	}
	outlook = result.(map[string]any)
	if outlook["sample_count"] != 0 || outlook["reason"] != "clock_changed" {
		t.Fatalf("unexpected future outlook: %#v", outlook)
	}
}

func TestCapacityRejectsInputsPythonWouldRaiseOn(t *testing.T) {
	filesystem := raw(`{"state":"available","value":{"total":536870912000,"used":107374182400}}`)
	for _, test := range []struct {
		name       string
		rows       json.RawMessage
		filesystem json.RawMessage
	}{
		{"non-object row", raw(`[1]`), filesystem},
		{"unsafe integer", raw(`[{"ts":1800000000,"disk_used_gb":9007199254740992,"disk_total_gb":9007199254740992}]`), filesystem},
		{"missing state", raw(`[]`), raw(`{"value":{"total":1,"used":0}}`)},
		{"missing value", raw(`[]`), raw(`{"state":"available"}`)},
		{"missing total", raw(`[]`), raw(`{"state":"available","value":{"used":0}}`)},
	} {
		t.Run(test.name, func(t *testing.T) {
			_, err := Build(Request{Operation: "capacity_outlook", Args: []json.RawMessage{test.rows, test.filesystem, raw(`1800000000`)}})
			if err == nil {
				t.Fatal("expected capacity input error")
			}
		})
	}
}

func TestBooleanNowUsesPythonNumericSemantics(t *testing.T) {
	for _, now := range []string{"true", "false"} {
		result, err := Build(Request{
			Operation: "build_host_resources",
			Args:      []json.RawMessage{raw(samples()), raw(`[]`), raw(now)},
			Now:       testNow,
		})
		if err != nil {
			t.Fatalf("now %s: %v", now, err)
		}
		cpu := result.(map[string]any)["cpu"].(map[string]any)
		if cpu["reason"] != "clock_changed" {
			t.Fatalf("now %s: %#v", now, cpu)
		}
	}
}

func TestRunRejectsTrailingInput(t *testing.T) {
	input := `{"operation":"build_host_resources","args":[{},[]],"now":1800000000}{}`
	if err := Run(strings.NewReader(input), &bytes.Buffer{}); err == nil {
		t.Fatal("expected trailing input error")
	}
}
