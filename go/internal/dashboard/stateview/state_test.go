package stateview

import (
	"bytes"
	"encoding/json"
	"reflect"
	"strings"
	"testing"
)

func pointer[T any](value T) *T {
	return &value
}

func validRequest() Request {
	slots := make(map[string]int, len(fields)+1)
	for index, field := range fields {
		slots[field[1]] = index
	}
	slots["unused"] = 60
	return Request{
		Operation: "assemble",
		Input: Input{
			SlotCount:  pointer(64),
			Syncing:    pointer(false),
			TariNeeded: pointer(true),
			MoneroOnly: pointer(false),
			Slots:      slots,
			Stratum:    []StratumSlot{{Key: "stratum_port", Index: 61}},
			Window:     json.RawMessage("null"),
		},
	}
}

func TestBuildFullOrder(t *testing.T) {
	request := validRequest()
	value, err := Build(request)
	if err != nil {
		t.Fatal(err)
	}
	got := make([]string, len(value))
	for index, pair := range value {
		got[index] = pair[0].(string)
	}
	want := []string{
		"syncing", "tari_gates_sync", "page_title", "host_ip", "host_addr", "dashboard_onion",
		"stratum_port", "version", "update", "control_enabled", "os_update", "last_update", "range",
		"window", "avg_window", "avg_windows", "badges", "db_healthy", "hashrate", "system",
		"host_resources", "sync", "sync_status", "stratum", "pool", "network", "monero",
		"shares_window", "cadence", "raffle_eligible", "raffle_wins", "proxy_workers", "earnings",
		"earnings_summary", "xvb_calc", "xvb_standby", "tari", "workers", "energy", "proxy_summary",
		"share_stats", "reject_pct_24h", "blocks", "payouts", "disk_growth", "xvb_history", "egress",
		"topology", "chart",
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("keys = %#v", got)
	}
	if value[0][1] != (Ref{Ref: request.Input.Slots["metrics.global_syncing"]}) {
		t.Fatalf("syncing = %#v", value[0][1])
	}
}

func TestBuildFlagsWindowAndStratumOverwrite(t *testing.T) {
	request := validRequest()
	request.Input.Syncing = pointer(true)
	request.Input.MoneroOnly = pointer(true)
	request.Input.Window = json.RawMessage(`[62,63]`)
	request.Input.Stratum = []StratumSlot{
		{Key: "version", Index: 61},
		{Key: "stratum_host", Index: 60},
	}
	value, err := Build(request)
	if err != nil {
		t.Fatal(err)
	}
	if value[1][1] != false || value[2][1] != "Pithead Dashboard - Syncing" {
		t.Fatalf("flags = %#v, %#v", value[1], value[2])
	}
	if value[6] != (Pair{"version", Ref{Ref: 61}}) || value[8] != (Pair{"version", Ref{Ref: request.Input.Slots["version"]}}) {
		t.Fatalf("version overwrite pairs = %#v, %#v", value[6], value[8])
	}
	wantWindow := map[string]Ref{"from": {Ref: 62}, "to": {Ref: 63}}
	if !reflect.DeepEqual(value[14][1], wantWindow) {
		t.Fatalf("window = %#v", value[14][1])
	}

	order := make([]string, 0, len(value))
	final := make(map[string]any, len(value))
	for _, pair := range value {
		key := pair[0].(string)
		if _, exists := final[key]; !exists {
			order = append(order, key)
		}
		final[key] = pair[1]
	}
	if order[6] != "version" || final["version"] != (Ref{Ref: request.Input.Slots["version"]}) {
		t.Fatalf("overwrite semantics = %#v, %#v", order, final["version"])
	}
}

func TestBuildAllowsHighOpaqueIndices(t *testing.T) {
	request := validRequest()
	request.Input.SlotCount = pointer(302)
	request.Input.Slots["unused"] = 300
	request.Input.Stratum = []StratumSlot{{Key: "stratum_host", Index: 301}}
	value, err := Build(request)
	if err != nil {
		t.Fatal(err)
	}
	if value[6] != (Pair{"stratum_host", Ref{Ref: 301}}) {
		t.Fatalf("stratum = %#v", value[6])
	}
}

func TestBuildRejectsInvalidPlans(t *testing.T) {
	tests := map[string]func(*Request){
		"operation":       func(request *Request) { request.Operation = "missing" },
		"missing count":   func(request *Request) { request.Input.SlotCount = nil },
		"missing syncing": func(request *Request) { request.Input.Syncing = nil },
		"missing required": func(request *Request) {
			request.Input.TariNeeded = nil
		},
		"missing monero only": func(request *Request) { request.Input.MoneroOnly = nil },
		"missing slots":       func(request *Request) { request.Input.Slots = nil },
		"missing stratum":     func(request *Request) { request.Input.Stratum = nil },
		"missing window":      func(request *Request) { request.Input.Window = nil },
		"missing required slot": func(request *Request) {
			delete(request.Input.Slots, "build_chart")
		},
		"bad extra slot":    func(request *Request) { request.Input.Slots["unused"] = 64 },
		"bad window":        func(request *Request) { request.Input.Window = json.RawMessage(`[1,64]`) },
		"empty stratum key": func(request *Request) { request.Input.Stratum[0].Key = "" },
		"bad stratum index": func(request *Request) { request.Input.Stratum[0].Index = -1 },
		"duplicate stratum key": func(request *Request) {
			request.Input.Stratum = append(request.Input.Stratum, request.Input.Stratum[0])
		},
	}
	for name, mutate := range tests {
		t.Run(name, func(t *testing.T) {
			request := validRequest()
			mutate(&request)
			if _, err := Build(request); err == nil {
				t.Fatal("invalid plan accepted")
			}
		})
	}
}

func TestRunEnvelopeAndInputBoundaries(t *testing.T) {
	request := validRequest()
	payload, err := json.Marshal(request)
	if err != nil {
		t.Fatal(err)
	}
	for _, forbidden := range []string{"history", "chart_rows", "workers"} {
		if bytes.Contains(payload, []byte(`"`+forbidden+`"`)) {
			t.Fatalf("request contains raw section %q: %s", forbidden, payload)
		}
	}
	var output bytes.Buffer
	if err := Run(bytes.NewReader(payload), &output); err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(output.String(), `{"ok":true,"value":[`) {
		t.Fatalf("output = %s", output.String())
	}
	if err := Run(strings.NewReader(string(payload)+` {}`), &bytes.Buffer{}); err == nil {
		t.Fatal("trailing input accepted")
	}
	unknown := strings.Replace(string(payload), `"operation":"assemble"`, `"operation":"assemble","extra":true`, 1)
	if err := Run(strings.NewReader(unknown), &bytes.Buffer{}); err == nil {
		t.Fatal("unknown field accepted")
	}
}

func TestStratumSlotJSONShape(t *testing.T) {
	var slot StratumSlot
	for _, payload := range []string{`["host"]`, `["host",1,2]`, `[1,2]`, `["host","2"]`} {
		if err := json.Unmarshal([]byte(payload), &slot); err == nil {
			t.Fatalf("invalid stratum slot accepted: %s", payload)
		}
	}
	if err := json.Unmarshal([]byte(`["host",2]`), &slot); err != nil {
		t.Fatal(err)
	}
}
