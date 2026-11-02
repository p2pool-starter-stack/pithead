package wizard

import (
	"encoding/json"
	"reflect"
	"testing"
)

func TestConfigValueTaggedRoundTripPreservesOrderAndNumbers(t *testing.T) {
	wire := `["dict",[["large",["int","123456789012345678901234567890"]],["items",["list",[["null",null],["float","-0.0"],["str","text"]]]],["enabled",["bool",true]]]]`
	var value ConfigValue
	if err := json.Unmarshal([]byte(wire), &value); err != nil {
		t.Fatal(err)
	}
	if keys := opKeys(&value); !reflect.DeepEqual(keys, []string{"large", "items", "enabled"}) {
		t.Fatalf("keys = %#v", keys)
	}
	encoded, err := json.Marshal(value)
	if err != nil {
		t.Fatal(err)
	}
	if string(encoded) != wire {
		t.Fatalf("wire = %s", encoded)
	}
	clone := value.Clone()
	clone.Set("large", opInt("7"))
	original, _ := value.Field("large")
	if original.Text != "123456789012345678901234567890" {
		t.Fatal("clone mutated input")
	}
}

func TestConfigValueRejectsMalformedWire(t *testing.T) {
	cases := []string{
		`["unknown",null]`,
		`["int","01"]`,
		`["int","-0"]`,
		`["float","not-a-number"]`,
		`["float","1.0",-1]`,
		`["dict",[["same",["null",null]],["same",["null",null]]]]`,
		`["list",[null]]`,
		`["list",null]`,
		`["dict",null]`,
	}
	for _, wire := range cases {
		var value ConfigValue
		if err := json.Unmarshal([]byte(wire), &value); err == nil {
			t.Fatalf("accepted %s", wire)
		}
	}
}

func TestConfigValuePythonNumericEquality(t *testing.T) {
	cases := []struct {
		left  *ConfigValue
		right *ConfigValue
		want  bool
	}{
		{opBool(true), opInt("1"), true},
		{opBool(false), &ConfigValue{Kind: "float", Text: "-0.0"}, true},
		{opInt("9007199254740992"), &ConfigValue{Kind: "float", Text: "9007199254740992.0"}, true},
		{opInt("9007199254740993"), &ConfigValue{Kind: "float", Text: "9007199254740992.0"}, false},
		{opInt("1"), &ConfigValue{Kind: "float", Text: "inf"}, false},
	}
	for _, test := range cases {
		if got := test.left.Equal(test.right); got != test.want {
			t.Fatalf("%#v == %#v: got %v", test.left, test.right, got)
		}
	}
}

func TestConfigValueNaNIdentityOnlyAppliesInsideContainers(t *testing.T) {
	left := &ConfigValue{Kind: "float", Text: "nan", Identity: 12}
	right := &ConfigValue{Kind: "float", Text: "nan", Identity: 12}
	other := &ConfigValue{Kind: "float", Text: "nan", Identity: 13}
	if left.Equal(right) {
		t.Fatal("direct NaN equality must be false")
	}
	if !opList(left).Equal(opList(right)) {
		t.Fatal("same NaN identity in containers must be equal")
	}
	if opList(left).Equal(opList(other)) {
		t.Fatal("different NaN identities must be unequal")
	}
}

func TestConfigValueSetDeletePreserveKeyPosition(t *testing.T) {
	value := opDict(opField("first", opInt("1")), opField("second", opInt("2")))
	value.Set("first", opInt("3"))
	value.Set("third", opInt("4"))
	removed, ok := value.Delete("second")
	if !ok || removed.Text != "2" {
		t.Fatalf("removed = %#v, %v", removed, ok)
	}
	if keys := opKeys(value); !reflect.DeepEqual(keys, []string{"first", "third"}) {
		t.Fatalf("keys = %#v", keys)
	}
}
