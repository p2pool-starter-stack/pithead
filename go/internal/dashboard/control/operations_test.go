package control

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func encodedValue(t *testing.T, value any) string {
	t.Helper()
	data, err := json.Marshal(value)
	if err != nil {
		t.Fatal(err)
	}
	return string(data)
}

func TestSubmitGenericShapeAndMetadata(t *testing.T) {
	value, err := Process(Request{
		Operation: "control-submit",
		ID:        "{12345678-1234-5678-90ab-1234567890ab}",
		Action:    "preview",
		Actor:     json.RawMessage(`7`),
		Config: json.RawMessage(`{"z":1,"_core_keys":["x"],"nested":{"_core_keys":2},"_unknown":3,"a":4,
			"_config_version_newer":true,"_editable_keys":[],"_confirm_keys":[],"_approval_keys":[],"_default_keys":[],"_last_apply":null}`),
		Version:  json.RawMessage(`null`),
		Confirm:  json.RawMessage(`"APPLY"`),
		Approval: json.RawMessage(`{"suffix":"1234"}`),
	})
	if err != nil {
		t.Fatal(err)
	}
	want := `[["id","12345678-1234-5678-90ab-1234567890ab"],["action","preview"],["actor",7],["config",{"z":1,"nested":{"_core_keys":2},"_unknown":3,"a":4}],["confirm","APPLY"],["approval",{"suffix":"1234"}]]`
	if got := encodedValue(t, value); got != want {
		t.Fatalf("\n got %s\nwant %s", got, want)
	}
}

func TestSubmitDefaultsAndWorkerShapes(t *testing.T) {
	generic, err := Process(Request{Operation: "control-submit", Action: "commit"})
	if err != nil {
		t.Fatal(err)
	}
	var pairs [][]json.RawMessage
	if err := json.Unmarshal([]byte(encodedValue(t, generic)), &pairs); err != nil {
		t.Fatal(err)
	}
	if len(pairs) != 3 || string(pairs[2][1]) != `""` {
		t.Fatal(encodedValue(t, generic))
	}
	if _, err := normalizeID(strings.Trim(string(pairs[0][1]), `"`)); err != nil {
		t.Fatal(err)
	}

	apply, err := Process(Request{
		Operation: "control-submit", Kind: "worker-apply",
		ID: "123456781234567890ab1234567890ab", Actor: json.RawMessage(`null`),
		Worker: json.RawMessage(`{"name":"rig"}`), Changes: json.RawMessage(`{"DONATION":4}`),
	})
	if err != nil {
		t.Fatal(err)
	}
	wantApply := `[["id","12345678-1234-5678-90ab-1234567890ab"],["action","worker-apply"],["actor",null],["worker",{"name":"rig"}],["changes",{"DONATION":4}]]`
	if got := encodedValue(t, apply); got != wantApply {
		t.Fatal(got)
	}

	upgrade, err := Process(Request{
		Operation: "control-submit", Kind: "worker-upgrade",
		ID: "12345678-1234-5678-90ab-1234567890ab", Actor: json.RawMessage(`"admin"`),
		Worker: json.RawMessage(`9`), Version: json.RawMessage(`{"proposed":"v1"}`),
	})
	if err != nil {
		t.Fatal(err)
	}
	if got := encodedValue(t, upgrade); !strings.Contains(got, `["worker",9],["version",{"proposed":"v1"}]`) {
		t.Fatal(got)
	}
}

func TestValidateWorkerChanges(t *testing.T) {
	cases := []struct {
		raw, want string
	}{
		{`{"DONATION":2,"pools":[]}`, ""},
		{`{}`, "changes must be a non-empty object of writable config keys"},
		{`[]`, "changes must be a non-empty object of writable config keys"},
		{`{"zzz":1,"ACCESS_TOKEN":"x","DONATION":1}`, "keys not writable via the control path: ACCESS_TOKEN, zzz"},
	}
	for _, item := range cases {
		value, err := Process(Request{Operation: "control-validate-worker", Changes: json.RawMessage(item.raw)})
		if err != nil || value != item.want {
			t.Fatalf("%s: %#v, %v", item.raw, value, err)
		}
	}
}

func TestResultPreservesRawJSON(t *testing.T) {
	directory := t.TempDir()
	id := "12345678-1234-5678-90ab-1234567890ab"
	raw := `{"large":123456789012345678901234567890,"value":NaN}`
	if err := os.WriteFile(filepath.Join(directory, id+".json"), []byte(raw), 0o600); err != nil {
		t.Fatal(err)
	}
	value, err := Process(Request{Operation: "control-result", Directory: directory, ID: "{123456781234567890ab1234567890ab}"})
	if err != nil || value != raw {
		t.Fatalf("%#v, %v", value, err)
	}
	pending, err := Process(Request{Operation: "control-result", Directory: directory, ID: "22345678-1234-5678-90ab-1234567890ab"})
	if err != nil || pending != nil {
		t.Fatalf("%#v, %v", pending, err)
	}
	if _, err := Process(Request{Operation: "control-result", Directory: directory, ID: "../audit"}); err == nil {
		t.Fatal("invalid id accepted")
	}
}

func TestResultRejectsInvalidUTF8(t *testing.T) {
	directory := t.TempDir()
	id := "12345678-1234-5678-90ab-1234567890ab"
	if err := os.WriteFile(filepath.Join(directory, id+".json"), []byte{0xff}, 0o600); err != nil {
		t.Fatal(err)
	}
	_, err := Process(Request{Operation: "control-result", Directory: directory, ID: id})
	typed, ok := err.(*Error)
	if !ok || typed.Kind != "UnicodeDecodeError" || typed.Message != "'utf-8' codec can't decode byte 0xff in position 0: invalid start byte" {
		t.Fatalf("%#v", err)
	}
}

func TestUUIDTextFormsMatchPython(t *testing.T) {
	accepted := map[string]string{
		"12345678-1234-5678-90ab-1234567890ab":          "12345678-1234-5678-90ab-1234567890ab",
		"123456781234567890ab1234567890ab":              "12345678-1234-5678-90ab-1234567890ab",
		"{123456781234567890ab1234567890ab}":            "12345678-1234-5678-90ab-1234567890ab",
		"urn:uuid:12345678-1234-5678-90ab-1234567890ab": "12345678-1234-5678-90ab-1234567890ab",
		"{12345678-1234-5678-90ab-1234567890ab":         "12345678-1234-5678-90ab-1234567890ab",
		"+23456781234567890ab1234567890ab":              "02345678-1234-5678-90ab-1234567890ab",
		"0x3456781234567890ab1234567890ab":              "00345678-1234-5678-90ab-1234567890ab",
		"0X3456781234567890ab1234567890ab":              "00345678-1234-5678-90ab-1234567890ab",
		"+0x456781234567890ab1234567890ab":              "00045678-1234-5678-90ab-1234567890ab",
	}
	for input, want := range accepted {
		got, err := normalizeID(input)
		if err != nil || got != want {
			t.Fatalf("%q: %q, %v", input, got, err)
		}
	}
	for _, input := range []string{"URN:UUID:12345678-1234-5678-90ab-1234567890ab", "-23456781234567890ab1234567890ab"} {
		if _, err := normalizeID(input); err == nil {
			t.Fatalf("accepted %q", input)
		}
	}
}
