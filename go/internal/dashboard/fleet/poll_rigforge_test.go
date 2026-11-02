package fleet

import (
	"bytes"
	"encoding/json"
	"errors"
	"math"
	"strconv"
	"strings"
	"testing"
	"time"
)

func TestParseRigforgeNormalizesValuesAndCredentials(t *testing.T) {
	generated := time.Date(2026, 9, 7, 5, 0, 0, 0, time.UTC).Unix()
	payload := map[string]any{
		"generated_at": "2026-9-7T5:0:0Z",
		"rigforge": map[string]any{
			"version": "1.10.0", "xmrig_api": "unreachable",
			"power":    map[string]any{"watts": json.Number("9007199254740993"), "hs_per_watt": json.Number("86.9")},
			"tune":     map[string]any{"target": "perf", "autotune": map[string]any{"enabled": "yes", "next": "Sun 03:00"}},
			"health":   map[string]any{"governor": "performance", "throttling": false, "firmware": map[string]any{"board": "ProArt"}, "hugepages_total": json.Number("1280")},
			"watchdog": map[string]any{"mode": "enabled", "thermal_hold": false, "temp_c": json.Number("62"), "max_temp_c": json.Number("85")},
			"config": map[string]any{
				"DONATION": json.Number("1"), "pools": []any{map[string]any{"url": "rig:3333", "pass": "secret", "tls-fingerprint": ""}}, "ACCESS_TOKEN": "leak",
			},
			"config_meta": map[string]any{"revision": "a1.b2-c3_d4", "changed_at": "2026-08-23T14:30:45Z", "source": "control", "last_change_id": "0f1e"},
		},
	}
	value, err := parseRigforge(payload, json.Number(strconv.FormatInt(generated+30, 10)))
	if err != nil {
		t.Fatal(err)
	}
	result := value.(map[string]any)
	if result["age_sec"].(json.Number).String() != "30" || result["stale"] != false || result["miner_down"] != true {
		t.Fatalf("freshness = %#v", result)
	}
	if result["power"].(map[string]any)["watts"].(json.Number).String() != "9007199254740993" {
		t.Fatalf("power = %#v", result["power"])
	}
	if result["tune"].(map[string]any)["autotune_enabled"] != true || result["watchdog"].(map[string]any)["temp_c"].(json.Number).String() != "62" {
		t.Fatalf("nullable blocks = %#v %#v", result["tune"], result["watchdog"])
	}
	config := result["config"].(map[string]any)
	if _, ok := config["ACCESS_TOKEN"]; ok {
		t.Fatalf("config = %#v", config)
	}
	pool := config["pools"].([]any)[0].(map[string]any)
	if pool["pass"].(map[string]any)["__secret__"] != true || pool["tls-fingerprint"] != "" {
		t.Fatalf("pool = %#v", pool)
	}
	meta := result["config_meta"].(map[string]any)
	if meta["revision"] != "a1.b2-c3_d4" || meta["source"] != "control" {
		t.Fatalf("meta = %#v", meta)
	}
}

func TestParseRigforgeFreshnessAndNullableFields(t *testing.T) {
	payload := map[string]any{"generated_at": "2026-09-07t05:00:00z", "rigforge": map[string]any{"watchdog": map[string]any{"mode": "disabled", "temp_c": 99}}}
	for _, test := range []struct {
		now   any
		age   string
		stale bool
	}{
		{json.Number("1788757230.5"), "30", false},
		{json.Number("1788757231.5"), "32", false},
		{json.Number("1788757261"), "61", true},
		{json.Number("100000000000000000000"), "99999999998211244032", true},
		{json.Number("1788757139"), "", true},
		{"bad", "", true},
	} {
		value, err := parseRigforge(payload, test.now)
		if err != nil {
			t.Fatal(err)
		}
		result := value.(map[string]any)
		age := ""
		if result["age_sec"] != nil {
			age = result["age_sec"].(json.Number).String()
		}
		if age != test.age || result["stale"] != test.stale {
			t.Errorf("now %v = age %#v stale %v", test.now, result["age_sec"], result["stale"])
		}
		watchdog := result["watchdog"].(map[string]any)
		if watchdog["enabled"] != false || watchdog["temp_c"] != nil {
			t.Fatalf("watchdog = %#v", watchdog)
		}
	}
	for _, payload := range []any{nil, []any{}, map[string]any{}, map[string]any{"rigforge": "bad"}} {
		value, err := parseRigforge(payload, json.Number("0"))
		if err != nil || value != nil {
			t.Errorf("payload %#v = %#v, %v", payload, value, err)
		}
	}
}

func TestParseRigforgeFreshnessNonfiniteBehavior(t *testing.T) {
	payload := map[string]any{"generated_at": "2026-09-07T05:00:00Z", "rigforge": map[string]any{}}
	for _, now := range []float64{math.Inf(-1), math.NaN()} {
		value, err := parseRigforge(payload, now)
		if err != nil || value.(map[string]any)["age_sec"] != nil {
			t.Errorf("now %v = %#v, %v", now, value, err)
		}
	}
	_, err := parseRigforge(payload, math.Inf(1))
	var pollErr *PollError
	if !errors.As(err, &pollErr) || pollErr.Kind != "OverflowError" {
		t.Fatalf("error = %#v", err)
	}
	_, err = parseRigforge(payload, json.Number(strings.Repeat("9", 400)))
	if !errors.As(err, &pollErr) || pollErr.Kind != "OverflowError" || pollErr.Message != "int too large to convert to float" {
		t.Fatalf("large integer error = %#v", err)
	}
}

func TestParseRigforgeMasksAtDepthAndNormalizesMeta(t *testing.T) {
	deep := map[string]any{}
	cursor := deep
	for range 7 {
		next := map[string]any{}
		cursor["nested"] = next
		cursor = next
	}
	cursor["pass"] = "secret"
	payload := map[string]any{"rigforge": map[string]any{
		"config": map[string]any{"watchdog": deep},
		"config_meta": map[string]any{
			"revision": strings.Repeat("x", 65), "changed_at": "not-a-stamp", "source": "vendor", "last_change_id": "valid_id",
		},
	}}
	value, err := parseRigforge(payload, json.Number("0"))
	if err != nil {
		t.Fatal(err)
	}
	result := value.(map[string]any)
	encoded, err := json.Marshal(result["config"])
	if err != nil || strings.Contains(string(encoded), "secret") {
		t.Fatalf("config = %s, %v", encoded, err)
	}
	meta := result["config_meta"].(map[string]any)
	if meta["revision"] != nil || meta["changed_at"] != nil || meta["source"] != nil || meta["last_change_id"] != "valid_id" {
		t.Fatalf("meta = %#v", meta)
	}
	unicodeMeta := normalizeRigforgeConfigMeta(map[string]any{
		"revision": "token\n", "changed_at": "٢٠٢٦-٠٨-٢٣T١٤:٣٠:٤٥Z\n",
	}).(map[string]any)
	if unicodeMeta["revision"] != "token\n" || unicodeMeta["changed_at"] != "٢٠٢٦-٠٨-٢٣T١٤:٣٠:٤٥Z\n" {
		t.Fatalf("unicode meta = %#v", unicodeMeta)
	}
}

func TestPollParseRigforgeReturnsStructuredAttributeError(t *testing.T) {
	request := pollRequest(t, "poll_parse_rigforge", 0, `{"rigforge":{"tune":"bad"}}`, `0`)
	request.Envelope = true
	var output bytes.Buffer
	if err := Run(strings.NewReader(mustJSON(t, request)), &output); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(output.String(), `"kind":"AttributeError"`) || !strings.Contains(output.String(), `'str' object has no attribute 'get'`) {
		t.Fatalf("output = %s", output.String())
	}
}

func TestPollMergeRigforgeStatsParsesOnceAndReusesMerge(t *testing.T) {
	workers := `[{
		"name":"rig","uptime":2,"h10":0,"h60":0,"h15":0
	},{"name":"missing","uptime":3}]`
	results := `[
		{"api_ok":true,"kind":"proxy","hashrate":{"total":[2,3,4]},"generated_at":"2026-09-07T05:00:00Z","rigforge":{"version":"1.10.0"}},
		null
	]`
	value := pollBuild(t, "poll_merge_rigforge_stats", 0, workers, results, `3333`, `[1788757230,1788757230]`)
	patches := value.([]any)
	if len(patches) != 2 {
		t.Fatalf("patches = %#v", patches)
	}
	first := patches[0].(map[string]any)
	if first["h15"].(json.Number).String() != "4000" || first["active_pool"].(json.Number).String() != "3333" {
		t.Fatalf("first = %#v", first)
	}
	rigforge := first["rigforge"].(map[string]any)
	if rigforge["version"] != "1.10.0" || rigforge["age_sec"].(json.Number).String() != "30" {
		t.Fatalf("rigforge = %#v", rigforge)
	}
	if _, ok := patches[1].(map[string]any)["rigforge"]; ok {
		t.Fatalf("second = %#v", patches[1])
	}
}

func TestPollMergeRigforgeStatsRejectsClockMisalignment(t *testing.T) {
	request := pollRequest(t, "poll_merge_rigforge_stats", 0, `[{}]`, `[null]`, `3333`, `[]`)
	request.Envelope = true
	var output bytes.Buffer
	if err := Run(strings.NewReader(mustJSON(t, request)), &output); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(output.String(), `"kind":"ValueError"`) || !strings.Contains(output.String(), `clocks length`) {
		t.Fatalf("output = %s", output.String())
	}
}

func TestParseRigforgeNonfiniteMalformedBlocksKeepFloatError(t *testing.T) {
	for _, value := range []float64{math.NaN(), math.Inf(1), math.Inf(-1)} {
		_, err := parseRigforge(map[string]any{"rigforge": map[string]any{"power": value}}, json.Number("0"))
		var detail *PollError
		if !errors.As(err, &detail) || detail.Kind != "AttributeError" || detail.Message != "'float' object has no attribute 'get'" {
			t.Fatalf("error = %#v", err)
		}
	}
}
