package wizard

import (
	"encoding/json"
	"fmt"
	"reflect"
	"testing"
	"time"
)

func TestAuditDiffFlatteningCollisionsAndVersion(t *testing.T) {
	old := opDict(
		opField("a", opDict(opField("b", opInt("1")))),
		opField("a.b", opInt("2")),
		opField("reverse.path", opInt("2")),
		opField("reverse", opDict(opField("path", opInt("1")))),
		opField("empty", opDict()),
		opField("config_version", opString("old")),
		opField("config_version.inner", opString("old")),
		opField("nested", opDict(opField("config_version", opString("old")))),
	)
	newValue := opDict(
		opField("a.b", opInt("2")),
		opField("reverse.path", opInt("2")),
		opField("empty", opDict(opField("added", opBool(true)))),
		opField("config_version", opString("new")),
		opField("config_version.inner", opString("new")),
		opField("nested", opDict(opField("config_version", opString("new")))),
	)
	got, err := auditDiff(opDict(opField("old", old), opField("new", newValue)))
	if err != nil {
		t.Fatal(err)
	}
	if values := editorStrings(got); !reflect.DeepEqual(values, []string{"empty.added", "nested.config_version", "reverse.path"}) {
		t.Fatalf("paths = %#v", values)
	}
}

func TestAuditDiffSecretNumericEqualityAndContainers(t *testing.T) {
	nanOne := &ConfigValue{Kind: "float", Text: "NaN", Identity: 1}
	nanTwo := &ConfigValue{Kind: "float", Text: "NaN", Identity: 2}
	old := opDict(
		opField("secret", opDict(opField("__secret__", opBool(true)))),
		opField("number", opBool(true)),
		opField("same_nan_list", opList(nanOne)),
		opField("different_nan_list", opList(nanOne)),
		opField("direct_nan", nanOne),
	)
	newValue := opDict(
		opField("secret", opDict(opField("__secret__", opInt("1")))),
		opField("number", opInt("1")),
		opField("same_nan_list", opList(nanOne.Clone())),
		opField("different_nan_list", opList(nanTwo)),
		opField("direct_nan", nanOne.Clone()),
	)
	got, err := auditDiff(opDict(opField("old", old), opField("new", newValue)))
	if err != nil {
		t.Fatal(err)
	}
	if values := editorStrings(got); !reflect.DeepEqual(values, []string{"different_nan_list", "direct_nan"}) {
		t.Fatalf("paths = %#v", values)
	}

	notSentinel := opDict(opField("__secret__", opBool(true)), opField("slot", opInt("1")))
	got, err = auditDiff(opDict(
		opField("old", opDict(opField("secret", notSentinel))),
		opField("new", opDict(opField("secret", opDict(opField("__secret__", opBool(true)), opField("slot", opInt("2")))))),
	))
	if err != nil || !reflect.DeepEqual(editorStrings(got), []string{"secret.slot"}) {
		t.Fatalf("non-sentinel = %#v, error = %v", editorStrings(got), err)
	}
}

func TestAuditDiffSurrogateSortAndNonDictRoots(t *testing.T) {
	empty, err := auditDiff(opDict(opField("old", opList(opInt("1"))), opField("new", opString("ignored"))))
	if err != nil || len(empty.Items) != 0 {
		t.Fatalf("non-dict roots = %#v, error = %v", empty, err)
	}

	surrogate := string([]byte{0xed, 0xa0, 0x80})
	got, err := auditDiff(opDict(
		opField("old", opList()),
		opField("new", opDict(opField(surrogate, opInt("1")), opField("z", opInt("1")))),
	))
	if err != nil {
		t.Fatal(err)
	}
	if values := editorStrings(got); !reflect.DeepEqual(values, []string{"z", surrogate}) {
		t.Fatalf("paths = %#v", values)
	}
	encoded, err := json.Marshal(got)
	if err != nil {
		t.Fatal(err)
	}
	var decoded ConfigValue
	if err := json.Unmarshal(encoded, &decoded); err != nil || !got.Equal(&decoded) {
		t.Fatalf("surrogate round trip = %x, error = %v", encoded, err)
	}
}

func TestAuditUnexplainedPreservesOrderAndDuplicates(t *testing.T) {
	got, err := auditUnexplained(opDict(
		opField("changed", configStrings([]string{"pool.host", "other", "pool", "pool.host", ".child"})),
		opField("explained", configStrings([]string{"pool", ""})),
	))
	if err != nil {
		t.Fatal(err)
	}
	if values := editorStrings(got); !reflect.DeepEqual(values, []string{"other"}) {
		t.Fatalf("paths = %#v", values)
	}

	got, err = auditUnexplained(opDict(
		opField("changed", configStrings([]string{"same", "same", "sibling.child"})),
		opField("explained", configStrings([]string{"different"})),
	))
	if err != nil || !reflect.DeepEqual(editorStrings(got), []string{"same", "same", "sibling.child"}) {
		t.Fatalf("duplicates = %#v, error = %v", editorStrings(got), err)
	}
}

func TestAuditPolicyScalesAndDoesNotMutate(t *testing.T) {
	const count = 20000
	oldFields := make([]ConfigField, count)
	newFields := make([]ConfigField, count)
	changed := make([]string, count)
	for index := 0; index < count; index++ {
		key := fmt.Sprintf("key-%05d", index)
		oldFields[index] = opField(key, opInt("1"))
		newFields[index] = opField(key, opInt("1"))
		changed[index] = key
	}
	newFields[count-1].Value = opInt("2")
	arguments := opDict(opField("old", opDict(oldFields...)), opField("new", opDict(newFields...)))
	before, err := json.Marshal(arguments)
	if err != nil {
		t.Fatal(err)
	}
	started := time.Now()
	diff, err := auditDiff(arguments)
	if err != nil || !reflect.DeepEqual(editorStrings(diff), []string{"key-19999"}) {
		t.Fatalf("diff = %#v, error = %v", editorStrings(diff), err)
	}
	unexplained, err := auditUnexplained(opDict(
		opField("changed", configStrings(changed)),
		opField("explained", configStrings([]string{"key-00000"})),
	))
	if err != nil || len(unexplained.Items) != count-1 {
		t.Fatalf("unexplained count = %d, error = %v", len(unexplained.Items), err)
	}
	after, err := json.Marshal(arguments)
	if err != nil || string(before) != string(after) {
		t.Fatalf("input mutated: %v", err)
	}
	if elapsed := time.Since(started); elapsed > 5*time.Second {
		t.Fatalf("audit policy took %s", elapsed)
	}
}

func TestAuditPolicyConfigProtocol(t *testing.T) {
	diff := runConfigRequest(t, ConfigRequest{
		Operation: "audit-diff",
		Config: opDict(
			opField("old", opDict(opField("key", opInt("1")))),
			opField("new", opDict(opField("key", opInt("2")))),
		),
	})
	if !diff.OK || diff.Error != nil {
		t.Fatalf("diff response = %#v", diff)
	}
	var paths ConfigValue
	if err := json.Unmarshal(diff.Value, &paths); err != nil || !reflect.DeepEqual(editorStrings(&paths), []string{"key"}) {
		t.Fatalf("diff value = %s, error = %v", diff.Value, err)
	}

	unexplained := runConfigRequest(t, ConfigRequest{
		Operation: "audit-unexplained",
		Config: opDict(
			opField("changed", configStrings([]string{"key.child"})),
			opField("explained", configStrings([]string{"key"})),
		),
	})
	if !unexplained.OK || unexplained.Error != nil {
		t.Fatalf("unexplained response = %#v", unexplained)
	}
}
