package fleet

import (
	"encoding/json"
	"fmt"
	"reflect"
	"testing"
	"time"
)

func TestPollTelemetryHourlyGateAndValues(t *testing.T) {
	due := pollBuild(t, "poll_telemetry_hourly", 0,
		`4600`, `1000`, `3600`, `{"db_size":null}`, `{"used_gb":-0.0,"total_gb":500}`).(map[string]any)
	if due["due"] != true || !reflect.DeepEqual(due["values"], []any{json.Number("0"), json.Number("0"), json.Number("500")}) {
		t.Fatalf("due = %#v", due)
	}
	falsyDisk := pollBuild(t, "poll_telemetry_hourly", 0,
		`4600`, `1000`, `3600`, `{}`, `false`).(map[string]any)
	if !reflect.DeepEqual(falsyDisk["values"], []any{json.Number("0"), json.Number("0"), json.Number("0")}) {
		t.Fatalf("falsy disk = %#v", falsyDisk)
	}
	_, err := Build(pollRequest(t, "poll_telemetry_hourly", 0, `4600`, `1000`, `3600`, `false`, `{}`))
	if detail, ok := err.(*PollError); !ok || detail.Kind != "AttributeError" || detail.Message != "'bool' object has no attribute 'get'" {
		t.Fatalf("error = %#v", err)
	}
	for _, values := range [][]string{
		{`4599`, `1000`, `3600`},
		{`900`, `1000`, `3600`},
		{`1000`, `4600`, `3600`},
	} {
		result := pollBuild(t, "poll_telemetry_hourly", 0, values[0], values[1], values[2], `"unread"`, `"unread"`).(map[string]any)
		if result["due"] != false || len(result["values"].([]any)) != 0 {
			t.Fatalf("not due = %#v", result)
		}
	}
}

func TestPollTelemetryNetworkDefaultsAndFailures(t *testing.T) {
	result := pollBuild(t, "poll_telemetry_network", 0,
		`{"difficulty":null,"height":7,"reward":"kept"}`, `{"hashrate":false}`).([]any)
	if !reflect.DeepEqual(result, []any{json.Number("0"), json.Number("7"), "kept", json.Number("0")}) {
		t.Fatalf("network = %#v", result)
	}
	request := pollRequest(t, "poll_telemetry_network", 0, `false`, `{}`)
	request.Envelope = true
	value, err := Build(request)
	if err == nil || value != nil {
		t.Fatalf("error = %#v, value = %#v", err, value)
	}
	detail := err.(*PollError)
	if detail.Kind != "AttributeError" || detail.Message != "'bool' object has no attribute 'get'" {
		t.Fatalf("detail = %#v", detail)
	}
}

func TestPollTelemetryWorkerDue(t *testing.T) {
	for _, test := range []struct {
		name     string
		now      string
		last     string
		interval string
		want     bool
	}{
		{name: "inclusive", now: `1300`, last: `1000`, interval: `300`, want: true},
		{name: "early", now: `1299`, last: `1000`, interval: `300`, want: false},
		{name: "backward", now: `900`, last: `1000`, interval: `300`, want: false},
		{name: "future capture", now: `1000`, last: `1300`, interval: `300`, want: false},
	} {
		t.Run(test.name, func(t *testing.T) {
			value := pollBuild(t, "poll_telemetry_worker_due", 0, test.now, test.last, test.interval)
			if value != test.want {
				t.Fatalf("due = %#v", value)
			}
		})
	}
}

func TestPollTelemetryWorkersFiltersAndPreservesValues(t *testing.T) {
	workers := `[{"status":"offline","name":{"ignored":true}},{"status":"online","name":null,"h15":null,"accepted":-0,"rejected":"kept"},{"status":"online"}]`
	result := pollBuild(t, "poll_telemetry_workers", 0, `1300`, `1000`, `300`, workers).(map[string]any)
	want := []any{
		[]any{json.Number("1300"), nil, json.Number("0"), json.Number("0"), "kept"},
		[]any{json.Number("1300"), "", json.Number("0"), json.Number("0"), json.Number("0")},
	}
	if result["due"] != true || !reflect.DeepEqual(result["rows"], want) {
		t.Fatalf("workers = %#v", result)
	}
	notDue := pollBuild(t, "poll_telemetry_workers", 0, `1299`, `1000`, `300`, `["unread"]`).(map[string]any)
	if notDue["due"] != false || len(notDue["rows"].([]any)) != 0 {
		t.Fatalf("not due = %#v", notDue)
	}
	_, err := Build(pollRequest(t, "poll_telemetry_workers", 0, `1300`, `1000`, `300`, `["bad"]`))
	if detail, ok := err.(*PollError); !ok || detail.Kind != "AttributeError" || detail.Message != "'str' object has no attribute 'get'" {
		t.Fatalf("error = %#v", err)
	}
}

func TestPollTelemetryWorkersScalesAndDoesNotMutateInput(t *testing.T) {
	const count = 20000
	workers := make([]any, count)
	for index := range workers {
		workers[index] = map[string]any{
			"status": "online", "name": fmt.Sprintf("rig-%d", index),
			"h15": index, "accepted": index + 1, "rejected": 0,
		}
	}
	before, err := json.Marshal(workers)
	if err != nil {
		t.Fatal(err)
	}
	started := time.Now()
	result := pollBuildValues(t, "poll_telemetry_workers", 0, 300, 0, 300, workers).(map[string]any)
	if len(result["rows"].([]any)) != count {
		t.Fatalf("row count = %d", len(result["rows"].([]any)))
	}
	after, err := json.Marshal(workers)
	if err != nil {
		t.Fatal(err)
	}
	if string(before) != string(after) {
		t.Fatal("workers mutated")
	}
	if elapsed := time.Since(started); elapsed > 5*time.Second {
		t.Fatalf("worker planning took %s", elapsed)
	}
}
