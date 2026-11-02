package wizard

import (
	"encoding/json"
	"reflect"
	"strings"
	"testing"
)

func TestEditorLeafPathsPreservesOrderAndClassificationRules(t *testing.T) {
	reference := opDict(
		opField("config_version", opString("2.0.0")),
		opField("_last_apply", opDict(opField("status", opString("applied")))),
		opField("first", opDict(
			opField("value", opInt("1")),
			opField("_private", opString("skip")),
			opField("secret", opDict(opField("__secret__", opBool(true)), opField("slot", opInt("1")))),
			opField("not_secret", opDict(opField("__secret__", opInt("1")), opField("value", opString("kept")))),
		)),
		opField("items", opList(opString("one"))),
	)

	value, err := EditorLeafPaths(reference, nil, false)
	if err != nil {
		t.Fatal(err)
	}
	if got, want := editorTestStrings(value), []string{"first.value", "first.secret", "first.not_secret.value"}; !reflect.DeepEqual(got, want) {
		t.Fatalf("leaf paths = %#v, want %#v", got, want)
	}
	value, err = EditorLeafPaths(reference, opList(opString("nested")), true)
	if err != nil {
		t.Fatal(err)
	}
	if got, want := editorTestStrings(value), []string{"nested.config_version", "nested.first.value", "nested.first.secret", "nested.first.not_secret.value", "nested.items"}; !reflect.DeepEqual(got, want) {
		t.Fatalf("prefixed leaves = %#v, want %#v", got, want)
	}
}

func TestEditorApprovalConfirmedAndDefaults(t *testing.T) {
	reference := opDict(
		opField("zeta", opString("")),
		opField("telegram", opDict(opField("enabled", opBool(true)))),
		opField("dashboard", opDict(opField("host", opString("box")))),
		opField("ssh", opDict(opField("enabled", opBool(false)))),
		opField("workers", opDict(opField("list", opList()), opField("port", opInt("1")))),
	)
	approval, err := EditorApprovalPaths(
		reference,
		configStrings([]string{"zeta"}),
		configStrings([]string{"dashboard.host"}),
		configStrings([]string{"telegram.enabled", "dashboard.host", "ssh.enabled"}),
	)
	if err != nil {
		t.Fatal(err)
	}
	if got, want := editorTestStrings(approval), []string{"telegram.enabled"}; !reflect.DeepEqual(got, want) {
		t.Fatalf("approval = %#v, want %#v", got, want)
	}
	confirmed, err := EditorConfirmedPaths(reference, configStrings([]string{"zeta"}), configStrings([]string{"dashboard.host"}), approval)
	if err != nil {
		t.Fatal(err)
	}
	if got, want := editorTestStrings(confirmed), []string{"workers.port"}; !reflect.DeepEqual(got, want) {
		t.Fatalf("confirmed = %#v, want %#v", got, want)
	}
	defaults, err := EditorMissingDefaults(reference, opDict(
		opField("zeta", configNull()),
		opField("workers", opDict(opField("list", opList()))),
	))
	if err != nil {
		t.Fatal(err)
	}
	if got, want := editorTestStrings(defaults), []string{"telegram.enabled", "dashboard.host", "ssh.enabled", "workers.port"}; !reflect.DeepEqual(got, want) {
		t.Fatalf("defaults = %#v, want %#v", got, want)
	}
}

func TestEditorMandatoryPathListsRejectNullInOrder(t *testing.T) {
	reference := opDict(opField("value", opBool(true)))
	if _, err := EditorLeafPaths(reference, configNull(), false); err != nil {
		t.Fatalf("optional null prefix: %v", err)
	}
	for _, test := range []struct {
		name     string
		free     *ConfigValue
		confirm  *ConfigValue
		approval *ConfigValue
	}{
		{"free_paths", configNull(), opList(), opList()},
		{"confirm_paths", opList(), configNull(), opList()},
		{"approval_paths", opList(), opList(), configNull()},
	} {
		_, err := EditorConfirmedPaths(reference, test.free, test.confirm, test.approval)
		if typeError, ok := err.(configTypeError); !ok || typeError.Error() != test.name+" must be a list" {
			t.Fatalf("%s error = %#v", test.name, err)
		}
	}
	if _, err := EditorApprovalPaths(reference, opList(), opList(), configNull()); err == nil || err.Error() != "approval_named must be a list" {
		t.Fatalf("approval_named error = %#v", err)
	}
}

func TestEditorLastApplyIndexAndAttributeFailure(t *testing.T) {
	entries := opList(
		opDict(opField("action", opString("preview")), opField("status", opString("applied"))),
		opDict(opField("action", opString("commit-approved")), opField("status", opString("failed"))),
		opDict(opField("action", opString("commit")), opField("status", opString("applied"))),
	)
	selected, err := EditorLastApplyIndex(entries)
	if err != nil || selected.Kind != "int" || selected.Text != "1" {
		t.Fatalf("selected = %#v, err = %v", selected, err)
	}
	_, err = EditorLastApplyIndex(opList(opString("bad"), entries.Items[1]))
	if attribute, ok := err.(configAttributeError); !ok || attribute.Error() != "'str' object has no attribute 'get'" {
		t.Fatalf("attribute error = %#v", err)
	}
}

func TestEditorVersionMetadataMatchesStampPolicy(t *testing.T) {
	tests := []struct {
		stamp   *ConfigValue
		missing bool
		current string
		pop     bool
		newer   bool
	}{
		{opString("2.1.0"), false, "2.0.0-pre.1+build", false, true},
		{opString("2.0.0"), false, " vV2.0.0.9 ", false, false},
		{opString("2.0.0"), false, "١.٩.٠", false, true},
		{opString("99999.0.0"), false, "2.0.0", false, false},
		{opInt("17"), false, "2.0.0", false, false},
		{configNull(), true, "2.0.0", true, false},
	}
	for _, test := range tests {
		result, err := EditorVersionMetadata(test.stamp, test.missing, opString(test.current))
		if err != nil {
			t.Fatalf("stamp %v current %q: %v", test.stamp, test.current, err)
		}
		pop, _ := result.Field("pop_version")
		newer, _ := result.Field("newer")
		if pop.Bool != test.pop || newer.Bool != test.newer {
			t.Fatalf("stamp %v current %q = pop %v newer %v", test.stamp, test.current, pop.Bool, newer.Bool)
		}
	}
	_, err := EditorVersionMetadata(opString("2.0.0"), false, opString("².0.0"))
	if validation, ok := err.(ValidationError); !ok || validation.Error() != "invalid literal for int() with base 10: '²'" {
		t.Fatalf("unicode integer error = %#v", err)
	}
	result, err := EditorVersionMetadata(opString("2.0.0"), false, opString("².a.0"))
	if err != nil {
		t.Fatalf("later invalid digit must suppress conversion: %v", err)
	}
	newer, _ := result.Field("newer")
	if newer.Bool {
		t.Fatal("invalid current version classified as older")
	}
}

func TestEditorVersionMetadataHonorsIntegerDigitLimit(t *testing.T) {
	if _, err := EditorVersionMetadata(opString("2.0.0"), false, opString(strings.Repeat("9", 5000)+".bad.0")); err != nil {
		t.Fatalf("later invalid part must suppress digit limit: %v", err)
	}
	arguments := opDict(
		opField("stamp", opString("2.0.0")),
		opField("stamp_missing", opBool(false)),
		opField("current", opString("00000.0.0")),
		opField("max_digits", opInt("4")),
	)
	_, err := editorVersionFromArguments(arguments)
	want := "Exceeds the limit (4 digits) for integer string conversion: value has 5 digits; use sys.set_int_max_str_digits() to increase the limit"
	if validation, ok := err.(ValidationError); !ok || validation.Error() != want {
		t.Fatalf("digit limit error = %#v", err)
	}
	arguments.Set("max_digits", opInt("0"))
	if _, err := editorVersionFromArguments(arguments); err != nil {
		t.Fatalf("disabled digit limit: %v", err)
	}
}

func TestEditorProtocolOperationsAndMetadata(t *testing.T) {
	arguments := opDict(
		opField("reference", opDict(
			opField("config_version", opString("2.0.0")),
			opField("free", opBool(true)),
			opField("approval", opBool(true)),
			opField("confirmed", opBool(true)),
			opField("items", opList()),
		)),
		opField("approval_free", configStrings([]string{"free"})),
		opField("confirmed_free", configStrings([]string{"free"})),
		opField("explicit_confirm", configStrings([]string{"confirmed"})),
		opField("approval_named", configStrings([]string{"approval"})),
		opField("host", opDict(opField("free", configNull()))),
		opField("entries", opList(opDict(opField("action", opString("commit")), opField("status", opString("applied"))))),
		opField("stamp", opString("2.1.0")),
		opField("stamp_missing", opBool(false)),
		opField("current", opString("2.0.0")),
	)
	response := runConfigRequest(t, ConfigRequest{Operation: "editor-metadata", Config: arguments})
	if !response.OK || response.Error != nil {
		t.Fatalf("metadata response = %#v", response)
	}
	var metadata ConfigValue
	if err := json.Unmarshal(response.Value, &metadata); err != nil {
		t.Fatal(err)
	}
	confirm, _ := metadata.Field("confirm_keys")
	approval, _ := metadata.Field("approval_keys")
	defaults, _ := metadata.Field("default_keys")
	lastApply, _ := metadata.Field("last_apply_index")
	pop, _ := metadata.Field("pop_version")
	newer, _ := metadata.Field("newer")
	if !reflect.DeepEqual(editorTestStrings(confirm), []string{"confirmed"}) || !reflect.DeepEqual(editorTestStrings(approval), []string{"approval"}) {
		t.Fatalf("metadata classes = confirm %#v approval %#v", editorTestStrings(confirm), editorTestStrings(approval))
	}
	if !reflect.DeepEqual(editorTestStrings(defaults), []string{"approval", "confirmed", "items"}) || lastApply.Text != "0" || pop.Bool || !newer.Bool {
		t.Fatalf("metadata = %#v", metadata)
	}

	response = runConfigRequest(t, ConfigRequest{Operation: "editor-last-apply", Config: opDict(opField("entries", opList(opInt("1"))))})
	if response.OK || response.Error == nil || response.Error.Kind != "AttributeError" {
		t.Fatalf("attribute response = %#v", response)
	}
}

func editorTestStrings(value *ConfigValue) []string {
	result := make([]string, len(value.Items))
	for index, item := range value.Items {
		result[index] = item.Text
	}
	return result
}
