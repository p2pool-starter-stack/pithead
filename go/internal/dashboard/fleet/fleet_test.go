package fleet

import (
	"bytes"
	"encoding/json"
	"math"
	"strings"
	"testing"
)

const testNow = 1790884800

func request(t *testing.T, operation string, values ...any) Request {
	t.Helper()
	raw := make([]json.RawMessage, len(values))
	for index, value := range values {
		encoded, err := json.Marshal(value)
		if err != nil {
			t.Fatal(err)
		}
		raw[index] = encoded
	}
	return Request{Operation: operation, Args: raw, Now: testNow}
}

func resultObject(t *testing.T, value any) map[string]any {
	t.Helper()
	result, ok := value.(map[string]any)
	if !ok {
		t.Fatalf("expected object, got %T", value)
	}
	return result
}

func TestRigforgeDisplayCurrentAndStale(t *testing.T) {
	current := map[string]any{
		"generated_at": "2026-10-01T20:00:00Z", "version": "1.7.0",
		"power":    map[string]any{"watts": 142.0, "hs_per_watt": 86.9},
		"health":   map[string]any{"governor": "powersave", "hugepages_total": 1280},
		"watchdog": map[string]any{"enabled": true, "temp_c": 62, "max_temp_c": 85},
	}
	value, err := Build(request(t, "rigforge_display", current, false))
	if err != nil {
		t.Fatal(err)
	}
	display := resultObject(t, value)
	if display["stale"] != false || display["version"] != "1.7.0" {
		t.Fatalf("unexpected current display: %#v", display)
	}
	chips := display["chips"].([]any)
	if len(chips) != 3 || resultObject(t, chips[0])["text"] != "gov: powersave" || resultObject(t, chips[1])["text"] != "142 W" || resultObject(t, chips[2])["text"] != "62°C" {
		t.Fatalf("unexpected chips: %#v", chips)
	}
	stale := map[string]any{"generated_at": "2026-10-01T19:58:00Z", "version": "1.7.0", "miner_down": true}
	value, err = Build(request(t, "rigforge_display", stale, true))
	if err != nil {
		t.Fatal(err)
	}
	display = resultObject(t, value)
	if display["stale"] != true || display["version"] != nil || display["miner_down"] != false {
		t.Fatalf("unexpected stale display: %#v", display)
	}
	if got := resultObject(t, display["chips"].([]any)[0])["text"]; got != "agent stale for 2m 0s" {
		t.Fatalf("unexpected stale chip: %v", got)
	}
}

func TestBuildWorkersSortsFormatsAndUpdates(t *testing.T) {
	workers := []any{
		map[string]any{"name": "offline", "ip": "10.0.0.9", "status": "offline", "active_pool": "3344"},
		map[string]any{
			"name": "online", "ip": "10.0.0.1", "status": "online", "active_pool": "3333",
			"uptime": 3600, "h60": 5100, "h15": 5200, "accepted": 90, "rejected": 10, "invalid": 2,
			"rigforge": map[string]any{"generated_at": "2026-10-01T20:00:00Z", "version": "1.11.1"},
		},
		map[string]any{"name": "broken", "status": "online", "active_pool": "3333"},
	}
	release := map[string]any{"tag": "v1.11.2", "url": "https://example.invalid/v1.11.2"}
	value, err := Build(request(t, "build_workers", workers, release))
	if err != nil {
		t.Fatal(err)
	}
	rows := value.([]any)
	if len(rows) != 2 || resultObject(t, rows[0])["name"] != "online" {
		t.Fatalf("unexpected rows: %#v", rows)
	}
	row := resultObject(t, rows[0])
	if row["pool"] != "p2pool" || row["h60_str"] != "5.10 kH/s" || row["rejected_str"] != "10 (+2 inv)" {
		t.Fatalf("unexpected formatted row: %#v", row)
	}
	if resultObject(t, row["reject_flag"])["title"] != "High reject rate: 10.0% (10 rejected)" {
		t.Fatalf("unexpected reject flag: %#v", row["reject_flag"])
	}
	if resultObject(t, row["rigforge_update"])["latest"] != "v1.11.2" {
		t.Fatalf("unexpected update: %#v", row["rigforge_update"])
	}
}

func TestBuildEnergyMeasuredConfiguredAndLive(t *testing.T) {
	workers := []any{
		map[string]any{"name": "measured", "h60": 2000, "rigforge": map[string]any{"generated_at": "2026-10-01T20:00:00Z", "power": map[string]any{"watts": 100}}},
		map[string]any{"name": "estimated", "h60": 1000},
		map[string]any{"name": "unknown", "h60": 9000},
	}
	prices := map[string]any{"xmr": 333.97, "tari": 0.0004, "fetched_at": testNow - 60.4}
	config := map[string]any{"cost_per_kwh": 0.2, "xmr_price": 150, "tari_price": 2.5, "currency": "USD", "price_feed": true}
	endpoints := []any{map[string]any{"name": "estimated", "watts": 50}}
	value, err := Build(request(t, "build_energy", workers, prices, config, endpoints))
	if err != nil {
		t.Fatal(err)
	}
	energy := resultObject(t, value)
	if energy["available"] != true || energy["total_watts"] != 150.0 || energy["hs_per_watt"] != 20.0 || energy["incomplete"] != true {
		t.Fatalf("unexpected energy totals: %#v", energy)
	}
	if energy["xmr_price"].(json.Number).String() != "333.97" || resultObject(t, energy["price_source"])["age_sec"] != 60.0 {
		t.Fatalf("unexpected live prices: %#v", energy)
	}
	perWorker := energy["per_worker"].([]any)
	if resultObject(t, perWorker[1])["estimated"] != true || resultObject(t, perWorker[2])["watts"] != nil {
		t.Fatalf("unexpected worker energy: %#v", perWorker)
	}
}

func TestHelpersAndRunValidation(t *testing.T) {
	value, err := Build(request(t, "_ip_to_sort_int", "10.0.0.1"))
	if err != nil || value.(json.Number).String() != "167772161" {
		t.Fatalf("unexpected IP result: %v %v", value, err)
	}
	value, err = Build(request(t, "_num", true))
	if err != nil || value != nil {
		t.Fatalf("bool must not be numeric: %v %v", value, err)
	}
	value, err = Build(request(t, "_fmt", 62.0))
	if err != nil || value != "62" {
		t.Fatalf("unexpected format: %v %v", value, err)
	}
	workers := []any{map[string]any{"name": "r", "ip": "1.1.1.1", "status": "online", "uptime": "3600", "h60": "5100"}}
	value, err = Build(request(t, "build_workers", workers, nil))
	if err != nil {
		t.Fatal(err)
	}
	row := resultObject(t, value.([]any)[0])
	if row["uptime_str"] != "1h 0m" || row["h60_str"] != "5.10 kH/s" {
		t.Fatalf("unexpected coercive formatting: %#v", row)
	}
	input := `{"operation":"_fmt","args":[1],"now":0} {}`
	if err := Run(strings.NewReader(input), &bytes.Buffer{}); err == nil {
		t.Fatal("expected trailing input error")
	}
}

func TestLargeIntegerPresentationStaysExact(t *testing.T) {
	large := json.Number("9007199254740993")
	value, err := Build(request(t, "_num", large))
	if err != nil || value.(json.Number).String() != large.String() {
		t.Fatalf("large _num changed: %v %v", value, err)
	}
	value, err = Build(request(t, "_fmt", large))
	if err != nil || value != large.String() {
		t.Fatalf("large _fmt changed: %v %v", value, err)
	}
	if got := formatDuration(json.Number("100000000000000000000")); got != "1157407407407407d 9h 46m" {
		t.Fatalf("large duration changed: %q", got)
	}
	if got := formatDuration(json.Number("-1")); got != "23h 59m" {
		t.Fatalf("negative duration changed: %q", got)
	}
	rf := map[string]any{"generated_at": "2026-10-01T20:00:00Z", "health": map[string]any{"hugepages_total": large}}
	value, err = Build(request(t, "rigforge_display", rf, false))
	if err != nil {
		t.Fatal(err)
	}
	stats := resultObject(t, value)["stats"].([]any)
	if resultObject(t, stats[0])["value"] != large.String() {
		t.Fatalf("large hugepages changed: %#v", stats)
	}
}

func TestLargeShareAndEnergyNumbersStayExact(t *testing.T) {
	value, err := Build(request(t, "_reject_flag", json.Number("171136785840078868"), json.Number("9007199254740993")))
	if err != nil {
		t.Fatal(err)
	}
	flag := resultObject(t, value)
	if flag["title"] != "High reject rate: 5.0% (9007199254740993 rejected)" {
		t.Fatalf("large reject calculation changed: %#v", flag)
	}
	large := json.Number("9007199254740993")
	workers := []any{map[string]any{
		"name": "large", "h60": large,
		"rigforge": map[string]any{"generated_at": "2026-10-01T20:00:00Z", "power": map[string]any{"watts": large}},
	}}
	config := map[string]any{"cost_per_kwh": 0, "xmr_price": 0, "tari_price": 0, "currency": "USD", "price_feed": false}
	value, err = Build(request(t, "build_energy", workers, nil, config, []any{}))
	if err != nil {
		t.Fatal(err)
	}
	row := resultObject(t, resultObject(t, value)["per_worker"].([]any)[0])
	if row["hs"].(json.Number).String() != large.String() || row["watts"].(json.Number).String() != large.String() {
		t.Fatalf("large energy values changed: %#v", row)
	}
}

func TestFractionalRigforgeTimestampIsNotAccepted(t *testing.T) {
	rf := map[string]any{"generated_at": "2026-10-01T20:00:00.5Z", "version": "1.7.0"}
	value, err := Build(request(t, "rigforge_display", rf, false))
	if err != nil {
		t.Fatal(err)
	}
	display := resultObject(t, value)
	if display["stale"] != true || resultObject(t, display["chips"].([]any)[0])["text"] != "agent freshness unknown" {
		t.Fatalf("fractional timestamp was trusted: %#v", display)
	}
}

func TestPythonFloatGroupingAndNegativeZero(t *testing.T) {
	cases := map[string]string{
		"-0":  "0",
		"1e3": "1,000.0", "1.23e3": "1,230.0", "1e15": "1,000,000,000,000,000.0",
		"1e16": "1e+16", "1e-4": "0.0001", "1e-5": "1e-05",
		"1.2345678901234567e15": "1,234,567,890,123,456.8",
		"1.2345678901234567e16": "1.2345678901234568e+16", "-0.0": "-0.0",
	}
	for input, expected := range cases {
		got, err := comma(json.Number(input))
		if err != nil || got != expected {
			t.Errorf("comma(%s) = %q, %v; want %q", input, got, err, expected)
		}
	}
	negativeZero := math.Copysign(0, -1)
	value, err := Build(request(t, "_fmt", negativeZero))
	if err != nil || value != "0" {
		t.Fatalf("negative zero format = %v, %v", value, err)
	}
}

func TestLegacyRigforgeAgeKeepsPythonDurationInputs(t *testing.T) {
	for _, test := range []struct {
		age  any
		want string
	}{
		{true, "stale for 0m 1s"},
		{false, "stale for 0m 0s"},
		{"61", "stale for 1m 1s"},
		{"bad", "stale for 0s"},
		{nil, "freshness unknown"},
	} {
		value, err := Build(request(t, "rigforge_display", map[string]any{"age_sec": test.age}, false))
		if err != nil {
			t.Fatal(err)
		}
		row := resultObject(t, resultObject(t, value)["stats"].([]any)[0])
		if row["value"] != test.want {
			t.Errorf("age %v = %v; want %s", test.age, row["value"], test.want)
		}
	}
}

func TestIPSortAcceptsWhitespaceAroundOctets(t *testing.T) {
	value, err := Build(request(t, "_ip_to_sort_int", " 10. 0.0 .1 "))
	if err != nil || value.(json.Number).String() != "167772161" {
		t.Fatalf("whitespace IP = %v, %v", value, err)
	}
}
