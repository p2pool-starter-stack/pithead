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

func auditLogEntry(id, status string) *ConfigValue {
	return opDict(
		opField("ts", opString("2026-07-10T12:00:00Z")),
		opField("id", opString(id)),
		opField("actor", opString("admin")),
		opField("action", opString("commit")),
		opField("status", opString(status)),
		opField("keys", opString("XVB_ENABLED P2POOL_PORT")),
	)
}

func auditLogArguments(entries *ConfigValue, limit *ConfigValue) *ConfigValue {
	return opDict(opField("entries", entries), opField("limit", limit))
}

func auditFieldNames(value *ConfigValue) []string {
	names := make([]string, len(value.Fields))
	for index, field := range value.Fields {
		names[index] = field.Key
	}
	return names
}

func TestAuditRecentCleansBoundsAndOrders(t *testing.T) {
	oldest := auditLogEntry(strings.Repeat("i", 60), "previewed")
	oldest.Set("ts", opString(strings.Repeat("t", 40)))
	oldest.Set("actor", opString(`<script>"a'b\c`+"\x1b[31m"))
	oldest.Set("action", opString(strings.Repeat("a", 30)))
	oldest.Set("status", opString(strings.Repeat("s", 50)))
	oldest.Set("keys", opString(strings.Repeat("k", 500)))
	newest := auditLogEntry("terminal", "applied")
	newest.Set("foreign", opString("LEAK"))
	value, err := auditRecent(auditLogArguments(opList(oldest, newest), opInt("50")))
	if err != nil {
		t.Fatal(err)
	}
	if len(value.Items) != 2 {
		t.Fatalf("entries = %d", len(value.Items))
	}
	first := value.Items[0]
	if id, _ := first.Field("id"); id.Text != "terminal" {
		t.Fatalf("newest first = %#v", first)
	}
	second := value.Items[1]
	if names := auditFieldNames(second); !reflect.DeepEqual(names, []string{"ts", "id", "actor", "action", "status", "keys"}) {
		t.Fatalf("field order = %#v", names)
	}
	wantLengths := map[string]int{"ts": 32, "id": 36, "actor": 12, "action": 16, "status": 32, "keys": 400}
	for _, field := range second.Fields {
		if len(field.Value.Text) != wantLengths[field.Key] {
			t.Fatalf("%s length = %d, value = %q", field.Key, len(field.Value.Text), field.Value.Text)
		}
	}
	actor, _ := second.Field("actor")
	if actor.Text != "scriptabc31m" || len(second.Fields) != 6 {
		t.Fatalf("sanitized row = %#v", second)
	}
}

func TestAuditRecentPythonSliceLimits(t *testing.T) {
	entries := opList(
		auditLogEntry("oldest", "preview"),
		auditLogEntry("middle", "preview"),
		auditLogEntry("newest", "applied"),
	)
	tests := []struct {
		name  string
		limit *ConfigValue
		want  []string
	}{
		{"none", configNull(), []string{"newest", "middle", "oldest"}},
		{"positive", opInt("2"), []string{"newest", "middle"}},
		{"negative", opInt("-1"), []string{"newest", "middle"}},
		{"large negative", opInt("-100000000000000000000"), []string{}},
		{"true", opBool(true), []string{"newest"}},
		{"false", opBool(false), []string{}},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			value, err := auditRecent(auditLogArguments(entries, test.limit))
			if err != nil {
				t.Fatal(err)
			}
			ids := make([]string, len(value.Items))
			for index, item := range value.Items {
				id, _ := item.Field("id")
				ids[index] = id.Text
			}
			if !reflect.DeepEqual(ids, test.want) {
				t.Fatalf("ids = %#v", ids)
			}
		})
	}
	_, err := auditRecent(auditLogArguments(entries, opString("2")))
	var typeError configTypeError
	if !errors.As(err, &typeError) || err.Error() != "slice indices must be integers or None or have an __index__ method" {
		t.Fatalf("bad limit error = %v", err)
	}
}

func TestAuditRecentRejectsUnnormalizedFields(t *testing.T) {
	entry := auditLogEntry("id", "applied")
	entry.Set("actor", opList(opInt("1"), opBool(true)))
	_, err := auditRecent(auditLogArguments(opList(entry), opString("bad")))
	var typeError configTypeError
	if !errors.As(err, &typeError) || err.Error() != "audit fields must be strings" {
		t.Fatalf("error = %v", err)
	}
}

func TestAuditMirrorOldestFirstDefaultsAndFalsyIDs(t *testing.T) {
	terminal := auditLogEntry("same", "applied")
	preview := auditLogEntry("same", "previewed")
	missing := opDict(opField("id", opString("minimal")))
	arguments := opDict(opField("entries", opList(
		terminal,
		opDict(opField("id", configNull())),
		opDict(opField("id", opBool(false))),
		opDict(opField("id", opInt("0"))),
		missing,
		preview,
	)))
	before, _ := json.Marshal(arguments)
	value, err := auditMirror(arguments)
	if err != nil {
		t.Fatal(err)
	}
	if len(value.Items) != 3 {
		t.Fatalf("rows = %d", len(value.Items))
	}
	ids := make([]string, len(value.Items))
	statuses := make([]string, len(value.Items))
	for index, item := range value.Items {
		id, _ := item.Field("id")
		status, _ := item.Field("status")
		source, _ := item.Field("source")
		ids[index], statuses[index] = id.Text, status.Text
		if source.Text != "control" || !reflect.DeepEqual(auditFieldNames(item), []string{"id", "ts", "source", "actor", "action", "status", "keys"}) {
			t.Fatalf("row = %#v", item)
		}
	}
	if !reflect.DeepEqual(ids, []string{"same", "minimal", "same"}) || !reflect.DeepEqual(statuses, []string{"previewed", "", "applied"}) {
		t.Fatalf("ids = %#v, statuses = %#v", ids, statuses)
	}
	after, _ := json.Marshal(arguments)
	if string(before) != string(after) {
		t.Fatal("input mutated")
	}

	_, err = auditMirror(opDict(opField("entries", opList(opDict(opField("id", opInt("1")))))))
	var typeError configTypeError
	if !errors.As(err, &typeError) || err.Error() != "audit fields must be strings" {
		t.Fatalf("truthy non-string id error = %v", err)
	}
}

func TestAuditLogPolicyScalesWithoutMutation(t *testing.T) {
	const count = 1800
	items := make([]*ConfigValue, count)
	for index := range items {
		entry := auditLogEntry(fmt.Sprintf("id-%04d", index), "applied")
		entry.Set("keys", opString(strings.Repeat("K", 400)))
		items[index] = entry
	}
	arguments := auditLogArguments(opList(items...), configNull())
	before, err := json.Marshal(arguments)
	if err != nil || len(before) < 256*1024 {
		t.Fatalf("fixture bytes = %d, error = %v", len(before), err)
	}
	started := time.Now()
	value, err := auditRecent(arguments)
	if err != nil || len(value.Items) != count {
		t.Fatalf("rows = %d, error = %v", len(value.Items), err)
	}
	after, err := json.Marshal(arguments)
	if err != nil || string(before) != string(after) {
		t.Fatalf("input mutated: %v", err)
	}
	if elapsed := time.Since(started); elapsed > 5*time.Second {
		t.Fatalf("audit log policy took %s", elapsed)
	}
}

func TestAuditLogConfigProtocol(t *testing.T) {
	recent := runConfigRequest(t, ConfigRequest{
		Operation: "audit-recent",
		Config:    auditLogArguments(opList(auditLogEntry("id", "applied")), opInt("1")),
	})
	if !recent.OK || recent.Error != nil {
		t.Fatalf("recent response = %#v", recent)
	}
	var entries ConfigValue
	if err := json.Unmarshal(recent.Value, &entries); err != nil || entries.Kind != "list" || len(entries.Items) != 1 || entries.Items[0].Kind != "dict" {
		t.Fatalf("recent value = %s, error = %v", recent.Value, err)
	}

	mirror := runConfigRequest(t, ConfigRequest{
		Operation: "audit-mirror",
		Config:    opDict(opField("entries", &entries)),
	})
	if !mirror.OK || mirror.Error != nil {
		t.Fatalf("mirror response = %#v", mirror)
	}
}
