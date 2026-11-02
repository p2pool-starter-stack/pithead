package wizard

import (
	"errors"
	"reflect"
	"testing"
)

func opString(value string) *ConfigValue { return &ConfigValue{Kind: "str", Text: value} }
func opInt(value string) *ConfigValue    { return &ConfigValue{Kind: "int", Text: value} }
func opBool(value bool) *ConfigValue     { return &ConfigValue{Kind: "bool", Bool: value} }
func opList(values ...*ConfigValue) *ConfigValue {
	return &ConfigValue{Kind: "list", Items: values}
}
func opDict(fields ...ConfigField) *ConfigValue {
	return &ConfigValue{Kind: "dict", Fields: fields}
}
func opField(key string, value *ConfigValue) ConfigField {
	return ConfigField{Key: key, Value: value}
}

func TestDeepMergePreservesOrderAndInputs(t *testing.T) {
	base := opDict(
		opField("nested", opDict(opField("first", opInt("1")))),
		opField("replace", opString("old")),
	)
	over := opDict(
		opField("nested", opDict(opField("second", opInt("2")))),
		opField("replace", opString("new")),
		opField("added", opBool(true)),
	)
	got := DeepMerge(base, over)
	if keys := opKeys(got); !reflect.DeepEqual(keys, []string{"nested", "replace", "added"}) {
		t.Fatalf("keys = %#v", keys)
	}
	nested, _ := got.Field("nested")
	if keys := opKeys(nested); !reflect.DeepEqual(keys, []string{"first", "second"}) {
		t.Fatalf("nested keys = %#v", keys)
	}
	got.Set("mutated", opBool(true))
	if _, ok := base.Field("mutated"); ok {
		t.Fatal("merge mutated base")
	}
}

func TestStripDefaultsUsesPythonEqualityAndRetainsUnknownOrder(t *testing.T) {
	config := opDict(
		opField("enabled", opBool(true)),
		opField("count", opInt("1")),
		opField("_private", opString("drop")),
		opField("nested", opDict(opField("same", opString("x")), opField("extra", opString("keep")))),
		opField("unknown", opString("last")),
	)
	reference := opDict(
		opField("enabled", opInt("1")),
		opField("count", opBool(true)),
		opField("nested", opDict(opField("same", opString("x")))),
	)
	got := StripDefaults(config, reference)
	if keys := opKeys(got); !reflect.DeepEqual(keys, []string{"nested", "unknown"}) {
		t.Fatalf("keys = %#v", keys)
	}
	nested, _ := got.Field("nested")
	if keys := opKeys(nested); !reflect.DeepEqual(keys, []string{"extra"}) {
		t.Fatalf("nested keys = %#v", keys)
	}
}

func TestValidateMachineName(t *testing.T) {
	defaultHost := opString("auto")
	tests := []struct {
		name     string
		config   *ConfigValue
		previous *ConfigValue
		wantErr  string
	}{
		{"default", opDict(), opDict(), ""},
		{"new label", opDict(opField("dashboard", opDict(opField("host", opString("node-1"))))), opDict(), ""},
		{"unchanged legacy", opDict(opField("dashboard", opDict(opField("host", opString("node.example"))))), opDict(opField("dashboard", opDict(opField("host", opString("node.example"))))), ""},
		{"changed legacy", opDict(opField("dashboard", opDict(opField("host", opString("node.example"))))), opDict(), "Name this machine"},
		{"bad dashboard", opDict(opField("dashboard", opList())), opDict(), "dashboard must be an object"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			err := ValidateMachineName(test.config, test.previous, defaultHost)
			if test.wantErr == "" && err != nil {
				t.Fatal(err)
			}
			if test.wantErr != "" && (err == nil || !contains(err.Error(), test.wantErr)) {
				t.Fatalf("error = %v", err)
			}
		})
	}
}

func TestRecoveryStateNormalizesRememberedAttemptAndMode(t *testing.T) {
	changes := opDict(opField("changes", opList(opString("first"), opString("second"))))
	attempt := opDict(opField("disk", opString("disk-a")), opField("wipe", opString("data")))
	disks := opList(opDict(opField("name", opString("disk-a"))))
	remembered, selected, mode, err := RecoveryState(changes, attempt, disks, opString("set"))
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(remembered, []string{"first", "second"}) || mode != "set" {
		t.Fatalf("remembered=%#v mode=%q", remembered, mode)
	}
	if keys := opKeys(selected); !reflect.DeepEqual(keys, []string{"disk", "wipe"}) {
		t.Fatalf("attempt keys = %#v", keys)
	}

	badChanges := opDict(opField("changes", opList(opString("ok"), opInt("1"))))
	remembered, selected, mode, err = RecoveryState(badChanges, attempt, disks, opString("invalid"))
	if err != nil {
		t.Fatal(err)
	}
	if len(remembered) != 0 || len(selected.Fields) != 2 || mode != "auto" {
		t.Fatalf("remembered=%#v attempt=%#v mode=%q", remembered, selected, mode)
	}
}

func TestRecoveryStateMatchesPythonMembershipAndErrors(t *testing.T) {
	disks := opList(opDict(opField("name", opInt("1"))))
	attempt := opDict(opField("disk", opBool(true)), opField("wipe", opString("keep")))
	_, selected, _, err := RecoveryState(opDict(), attempt, disks, opString("auto"))
	if err != nil || len(selected.Fields) != 2 {
		t.Fatalf("selected=%#v error=%v", selected, err)
	}

	_, _, _, err = RecoveryState(opDict(), opDict(), opList(opDict()), opString("auto"))
	var keyError configKeyError
	if !errors.As(err, &keyError) || err.Error() != "'name'" {
		t.Fatalf("missing name error = %v", err)
	}

	unhashable := opDict(opField("disk", opList()), opField("wipe", opString("all")))
	_, _, _, err = RecoveryState(opDict(), unhashable, disks, opString("auto"))
	var typeError configTypeError
	if !errors.As(err, &typeError) || err.Error() != "unhashable type: 'list'" {
		t.Fatalf("unhashable error = %v", err)
	}
}

func opKeys(value *ConfigValue) []string {
	keys := make([]string, len(value.Fields))
	for index, field := range value.Fields {
		keys[index] = field.Key
	}
	return keys
}

func contains(value, fragment string) bool {
	for index := 0; index+len(fragment) <= len(value); index++ {
		if value[index:index+len(fragment)] == fragment {
			return true
		}
	}
	return false
}
