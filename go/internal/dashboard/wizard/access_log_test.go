package wizard

import (
	"encoding/json"
	"errors"
	"fmt"
	"reflect"
	"strings"
	"testing"
	"time"
)

func auditAccessArguments(available bool, entries, now, limit, threshold, methods *ConfigValue) *ConfigValue {
	return opDict(
		opField("available", opBool(available)),
		opField("entries", entries),
		opField("now", now),
		opField("limit", limit),
		opField("threshold", threshold),
		opField("methods", methods),
	)
}

func auditAccessEntryValue(ts string, status string, method, uri, user string, probe *ConfigValue) *ConfigValue {
	return opDict(
		opField("ts", auditFloatValue(ts)),
		opField("status", opInt(status)),
		opField("method", opString(method)),
		opField("uri", opString(uri)),
		opField("user", opString(user)),
		opField("probe", probe),
	)
}

func auditAccessField(value *ConfigValue, name string) *ConfigValue {
	field, _ := value.Field(name)
	return field
}

func TestAuditAccessUnavailableIgnoresOtherFields(t *testing.T) {
	got, err := auditAccess(opDict(opField("available", opBool(false)), opField("entries", opString("bad"))))
	if err != nil {
		t.Fatal(err)
	}
	if names := auditFieldNames(got); !reflect.DeepEqual(names, []string{"available", "entries", "failures_24h", "last_failure_ts", "rotate_hint"}) {
		t.Fatalf("field order = %#v", names)
	}
	if auditAccessField(got, "available").Bool || len(auditAccessField(got, "entries").Items) != 0 || auditAccessField(got, "failures_24h").Text != "0" || auditAccessField(got, "last_failure_ts").Kind != "null" || auditAccessField(got, "rotate_hint").Bool {
		t.Fatalf("result = %#v", got)
	}
}

func TestAuditAccessSanitizesSortsAndCountsOrdinaryFailures(t *testing.T) {
	entries := opList(
		auditAccessEntryValue("10", "401", "GET", `<script>/a?x=1`, strings.Repeat("u", 70), configNull()),
		auditAccessEntryValue("12", "401", "POST", "/new", "operator", opString("boot-health-v1")),
		auditAccessEntryValue("11", "401", "PATCH", "/middle", "operator", opString("other")),
		auditAccessEntryValue("-Inf", "999999999999999999999", "GET", "/old", "operator", configNull()),
	)
	arguments := auditAccessArguments(true, entries, auditFloatValue("86410"), opInt("3"), opInt("2"), opList(opString("GET"), opString("POST")))
	before, _ := json.Marshal(arguments)
	got, err := auditAccess(arguments)
	if err != nil {
		t.Fatal(err)
	}
	rows := auditAccessField(got, "entries").Items
	if len(rows) != 3 {
		t.Fatalf("rows = %d", len(rows))
	}
	if timestamps := []string{auditAccessField(rows[0], "ts").Text, auditAccessField(rows[1], "ts").Text, auditAccessField(rows[2], "ts").Text}; !reflect.DeepEqual(timestamps, []string{"12", "11", "10"}) {
		t.Fatalf("timestamps = %#v", timestamps)
	}
	if auditAccessField(rows[1], "method").Text != "?" || auditAccessField(rows[2], "uri").Text != "script/a?x=1" || len(auditAccessField(rows[2], "user").Text) != 64 {
		t.Fatalf("sanitized rows = %#v", rows)
	}
	if failures := auditAccessField(got, "failures_24h").Text; failures != "2" {
		t.Fatalf("failures = %s", failures)
	}
	if last := auditAccessField(got, "last_failure_ts"); last.Kind != "float" || last.Text != "11" {
		t.Fatalf("last failure = %#v", last)
	}
	if !auditAccessField(got, "rotate_hint").Bool {
		t.Fatal("rotate hint false")
	}
	after, _ := json.Marshal(arguments)
	if string(before) != string(after) {
		t.Fatal("input mutated")
	}
}

func TestAuditAccessWindowUsesPythonFloatRoundingAndProbeEquality(t *testing.T) {
	entries := opList(
		auditAccessEntryValue("9007199254740992", "401", "GET", "/edge", "u", configNull()),
		auditAccessEntryValue("9007199254740994", "401", "GET", "/future", "u", configNull()),
		auditAccessEntryValue("9007199254740992", "401", "GET", "/probe", "u", opString("BOOT-HEALTH-V1")),
	)
	got, err := auditAccess(auditAccessArguments(true, entries, opInt("9007199254827393"), configNull(), auditFloatValue("NaN"), opList(opString("GET"))))
	if err != nil {
		t.Fatal(err)
	}
	if failures := auditAccessField(got, "failures_24h").Text; failures != "3" {
		t.Fatalf("failures = %s", failures)
	}
	if auditAccessField(got, "rotate_hint").Bool {
		t.Fatal("NaN threshold rotated")
	}
}

func TestAuditAccessStableSortClampAndSliceLimits(t *testing.T) {
	entries := opList(
		auditAccessEntryValue("NaN", "99", "", "/first", "u", configNull()),
		auditAccessEntryValue("0", "599", "", "/second", "u", configNull()),
		auditAccessEntryValue("+Inf", "600", "", "/third", "u", configNull()),
	)
	arguments := auditAccessArguments(true, entries, opBool(false), opInt("-1"), opBool(false), opList())
	got, err := auditAccess(arguments)
	if err != nil {
		t.Fatal(err)
	}
	rows := auditAccessField(got, "entries").Items
	if len(rows) != 2 || auditAccessField(rows[0], "uri").Text != "/first" || auditAccessField(rows[1], "uri").Text != "/second" {
		t.Fatalf("stable rows = %#v", rows)
	}
	if auditAccessField(rows[0], "ts").Text != "0" || auditAccessField(rows[0], "status").Text != "0" || auditAccessField(rows[1], "status").Text != "599" {
		t.Fatalf("normalized rows = %#v", rows)
	}
	if !auditAccessField(got, "rotate_hint").Bool {
		t.Fatal("zero threshold did not rotate")
	}
	arguments.Set("limit", opString("2"))
	_, err = auditAccess(arguments)
	var typeError configTypeError
	if !errors.As(err, &typeError) || err.Error() != "slice indices must be integers or None or have an __index__ method" {
		t.Fatalf("limit error = %v", err)
	}
}

func TestAuditAccessPreservesSignedZeroOnStableTies(t *testing.T) {
	entries := opList(
		auditAccessEntryValue("-0", "401", "GET", "/first", "u", configNull()),
		auditAccessEntryValue("0", "401", "GET", "/second", "u", configNull()),
	)
	got, err := auditAccess(auditAccessArguments(true, entries, auditFloatValue("0"), configNull(), opInt("1"), opList(opString("GET"))))
	if err != nil {
		t.Fatal(err)
	}
	rows := auditAccessField(got, "entries").Items
	if auditAccessField(rows[0], "ts").Text != "-0" || auditAccessField(rows[1], "ts").Text != "0" {
		t.Fatalf("stable signed zeros = %#v", rows)
	}
	if last := auditAccessField(got, "last_failure_ts"); last.Text != "-0" {
		t.Fatalf("last failure = %#v", last)
	}
}

func TestAuditAccessRejectsInvalidPayloads(t *testing.T) {
	validEntry := auditAccessEntryValue("1", "200", "GET", "/", "u", configNull())
	base := func() *ConfigValue {
		return auditAccessArguments(true, opList(validEntry.Clone()), auditFloatValue("1"), configNull(), opInt("1"), opList(opString("GET")))
	}
	tests := []struct {
		name string
		edit func(*ConfigValue)
	}{
		{"available", func(value *ConfigValue) { value.Set("available", opInt("1")) }},
		{"entries", func(value *ConfigValue) { value.Set("entries", opString("bad")) }},
		{"entry", func(value *ConfigValue) { value.Set("entries", opList(opString("bad"))) }},
		{"now", func(value *ConfigValue) { value.Set("now", opString("bad")) }},
		{"huge now", func(value *ConfigValue) { value.Set("now", opInt("1"+strings.Repeat("0", 400))) }},
		{"threshold", func(value *ConfigValue) { value.Set("threshold", configNull()) }},
		{"methods", func(value *ConfigValue) { value.Set("methods", opList(opInt("1"))) }},
		{"ts", func(value *ConfigValue) {
			auditAccessField(auditAccessField(value, "entries").Items[0], "ts").Kind = "int"
		}},
		{"status", func(value *ConfigValue) {
			auditAccessField(auditAccessField(value, "entries").Items[0], "status").Kind = "bool"
		}},
		{"method", func(value *ConfigValue) {
			auditAccessField(auditAccessField(value, "entries").Items[0], "method").Kind = "list"
		}},
		{"uri", func(value *ConfigValue) {
			auditAccessField(auditAccessField(value, "entries").Items[0], "uri").Kind = "null"
		}},
		{"probe", func(value *ConfigValue) {
			auditAccessField(auditAccessField(value, "entries").Items[0], "probe").Kind = "int"
		}},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			arguments := base()
			test.edit(arguments)
			if _, err := auditAccess(arguments); err == nil {
				t.Fatal("expected error")
			}
		})
	}
}

func TestAuditAccessScalesToBoundedRetainedRows(t *testing.T) {
	const count = 20000
	entries := make([]*ConfigValue, count)
	for index := range entries {
		entries[index] = auditAccessEntryValue(fmt.Sprintf("%d", index), "200", "GET", "/status", "operator", configNull())
	}
	arguments := auditAccessArguments(true, opList(entries...), opInt("20000"), opInt("50"), opInt("10"), opList(opString("GET")))
	started := time.Now()
	got, err := auditAccess(arguments)
	if err != nil || len(auditAccessField(got, "entries").Items) != 50 {
		t.Fatalf("rows = %d, error = %v", len(auditAccessField(got, "entries").Items), err)
	}
	if elapsed := time.Since(started); elapsed > 5*time.Second {
		t.Fatalf("audit access took %s", elapsed)
	}
}

func TestAuditAccessConfigProtocol(t *testing.T) {
	response := runConfigRequest(t, ConfigRequest{
		Operation: "audit-access",
		Config: auditAccessArguments(true,
			opList(auditAccessEntryValue("1", "200", "GET", "/", "u", configNull())),
			auditFloatValue("1"), opInt("1"), opInt("3"), opList(opString("GET"))),
	})
	if !response.OK || response.Error != nil {
		t.Fatalf("response = %#v", response)
	}
	var result ConfigValue
	if err := json.Unmarshal(response.Value, &result); err != nil || result.Kind != "dict" || len(auditAccessField(&result, "entries").Items) != 1 {
		t.Fatalf("value = %s, error = %v", response.Value, err)
	}
}
