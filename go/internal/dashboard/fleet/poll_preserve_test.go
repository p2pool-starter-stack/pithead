package fleet

import (
	"encoding/json"
	"reflect"
	"strconv"
	"testing"
	"time"
)

func TestPollPreserveReportsSelectsNewerMatchingReports(t *testing.T) {
	now := time.Date(2026, 9, 29, 22, 2, 0, 0, time.UTC).Unix()
	current := []any{
		[]any{"rig", "192.0.2.1", "dict", "2026-09-29T22:01:00Z"},
		[]any{"other", "192.0.2.2", "dict", "2026-09-29T22:01:00Z"},
		[]any{"rig", "192.0.2.1", "dict", "2026-09-29T22:01:30Z"},
	}
	next := []any{
		[]any{"rig", "192.0.2.1", "dict", "2026-09-29T22:01:30Z"},
		[]any{"other", "192.0.2.3", "dict", "2026-09-29T22:00:00Z"},
		[]any{"missing", "192.0.2.4", "falsy", nil},
	}
	value := pollBuildValues(t, "poll_preserve_reports", 0, current, next, now).(map[string]any)
	if value["error"] != nil || !reflect.DeepEqual(value["replacements"], []any{[]any{json.Number("0"), json.Number("2")}}) {
		t.Fatalf("replacements = %#v", value)
	}
}

func TestPollPreserveReportsKeepsPythonDuplicateAndNumericKeys(t *testing.T) {
	now := time.Date(2026, 9, 29, 22, 2, 0, 0, time.UTC).Unix()
	current := []any{
		[]any{true, 2, "dict", "2026-09-29T22:01:00Z"},
		[]any{1, 2.0, "falsy", nil},
		[]any{true, 2, "dict", "2026-09-29T22:01:30Z"},
	}
	next := []any{[]any{1.0, 2, "falsy", nil}}
	value := pollBuildValues(t, "poll_preserve_reports", 0, current, next, now).(map[string]any)
	if value["error"] != nil || !reflect.DeepEqual(value["replacements"], []any{[]any{json.Number("0"), json.Number("2")}}) {
		t.Fatalf("replacements = %#v", value)
	}
	current[2] = []any{true, 2, "falsy", nil}
	if value := pollBuildValues(t, "poll_preserve_reports", 0, current, next, now).(map[string]any); len(value["replacements"].([]any)) != 0 || value["error"] != nil {
		t.Fatalf("last duplicate was not authoritative: %#v", value)
	}
}

func TestPollPreserveReportsUsesFeedAgeThenRawLexicalOrder(t *testing.T) {
	now := time.Date(2026, 9, 29, 22, 2, 0, 0, time.UTC).Unix()
	current := []any{
		[]any{"lexical", nil, "dict", "2026-9-29T22:1:0Z"},
		[]any{"future", nil, "dict", "2026-09-29T22:03:01Z"},
		[]any{"invalid-next", nil, "dict", "2026-09-29T22:01:00Z"},
	}
	next := []any{
		[]any{"lexical", nil, "dict", "2026-09-29T22:01:30Z"},
		[]any{"future", nil, "falsy", nil},
		[]any{"invalid-next", nil, "dict", "invalid"},
	}
	value := pollBuildValues(t, "poll_preserve_reports", 0, current, next, now).(map[string]any)
	want := []any{
		[]any{json.Number("0"), json.Number("0")},
		[]any{json.Number("2"), json.Number("2")},
	}
	if value["error"] != nil || !reflect.DeepEqual(value["replacements"], want) {
		t.Fatalf("replacements = %#v", value)
	}
}

func TestPollPreserveReportsRejectsTruthyMalformedNextOnlyAfterValidMatch(t *testing.T) {
	now := time.Date(2026, 9, 29, 22, 2, 0, 0, time.UTC).Unix()
	current := `[["valid",null,"dict","2026-09-29T22:01:00Z"],["invalid",null,"dict","bad"]]`
	for _, next := range []string{
		`[["other",null,"str",null]]`,
		`[["invalid",null,"list",null]]`,
	} {
		if value := pollBuild(t, "poll_preserve_reports", 0, current, next, jsonNumber(now)).(map[string]any); len(value["replacements"].([]any)) != 0 || value["error"] != nil {
			t.Fatalf("unexpected replacements = %#v", value)
		}
	}
	value := pollBuild(t, "poll_preserve_reports", 0, current, `[["valid",null,"falsy",null],["valid",null,"str",null]]`, jsonNumber(now)).(map[string]any)
	errorValue := value["error"].(map[string]any)
	if len(value["replacements"].([]any)) != 1 || errorValue["kind"] != "AttributeError" || errorValue["message"] != "'str' object has no attribute 'get'" {
		t.Fatalf("partial failure = %#v", value)
	}
}

func TestPollPreserveReportsRejectsUnhashableKeysAndDoesNotMutateRows(t *testing.T) {
	now := time.Date(2026, 9, 29, 22, 2, 0, 0, time.UTC).Unix()
	current := []any{[]any{"rig", nil, "dict", "2026-09-29T22:01:00Z"}}
	next := []any{[]any{"rig", nil, "falsy", nil}}
	beforeCurrent, beforeNext := mustJSONValue(t, current), mustJSONValue(t, next)
	_ = pollBuildValues(t, "poll_preserve_reports", 0, current, next, now)
	if mustJSONValue(t, current) != beforeCurrent || mustJSONValue(t, next) != beforeNext {
		t.Fatalf("inputs changed: %#v %#v", current, next)
	}
	value := pollBuild(t, "poll_preserve_reports", 0, `[[[],null,"dict",null]]`, `[]`, jsonNumber(now)).(map[string]any)
	errorValue := value["error"].(map[string]any)
	if len(value["replacements"].([]any)) != 0 || errorValue["kind"] != "TypeError" || errorValue["message"] != "unhashable type: 'list'" {
		t.Fatalf("unhashable result = %#v", value)
	}
}

func TestPollPreserveReportsScalesAcrossLargeFleets(t *testing.T) {
	const count = 20000
	now := time.Date(2026, 9, 29, 22, 2, 0, 0, time.UTC).Unix()
	current := make([]any, count)
	next := make([]any, count)
	for index := range count {
		name := "rig-" + jsonNumber(int64(index))
		current[index] = []any{name, nil, "dict", "2026-09-29T22:01:00Z"}
		next[index] = []any{name, nil, "falsy", nil}
	}
	value := pollBuildValues(t, "poll_preserve_reports", 0, current, next, now).(map[string]any)
	if value["error"] != nil || len(value["replacements"].([]any)) != count {
		t.Fatalf("result = %#v", value)
	}
}

func jsonNumber(value int64) string {
	return strconv.FormatInt(value, 10)
}

func mustJSONValue(t *testing.T, value any) string {
	t.Helper()
	encoded, err := json.Marshal(value)
	if err != nil {
		t.Fatal(err)
	}
	return string(encoded)
}
