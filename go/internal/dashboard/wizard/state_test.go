package wizard

import (
	"bytes"
	"encoding/json"
	"reflect"
	"strings"
	"testing"
)

func TestStatePrepareReturnsOrderedWork(t *testing.T) {
	result, err := HandleState(StateRequest{
		Phase:          "prepare",
		Stage:          "handoff",
		Attempt:        opDict(opField("known", opString("value")), opField("unknown", opInt("2"))),
		Reference:      opDict(opField("known", opString(""))),
		LegacyDefaults: opDict(),
	})
	if err != nil {
		t.Fatal(err)
	}
	if result.Next != "config" || result.Remember == nil || !*result.Remember || result.ReadHandoff == nil || !*result.ReadHandoff || result.NeedDefaults == nil || *result.NeedDefaults {
		t.Fatalf("result = %#v", result)
	}
	if keys := opKeys(result.Attempt); !reflect.DeepEqual(keys, []string{"known"}) {
		t.Fatalf("attempt keys = %#v", keys)
	}
	if got := stateTexts(result.Changes); !reflect.DeepEqual(got, []string{"unknown removed"}) {
		t.Fatalf("changes = %#v", got)
	}

	result, err = HandleState(StateRequest{
		Phase:          "prepare",
		Stage:          "setup",
		Attempt:        opDict(),
		LegacyDefaults: opDict(),
	})
	if err != nil {
		t.Fatal(err)
	}
	if *result.Remember || *result.ReadHandoff || !*result.NeedDefaults {
		t.Fatalf("empty result = %#v", result)
	}
}

func TestStateConfigUsesDefaultsAndMode(t *testing.T) {
	reference := opDict(opField("base", opInt("1")))
	defaults := opDict(opField("added", opString("default")))
	result, err := HandleState(StateRequest{
		Phase: "config", Reference: reference, Attempt: opDict(), Defaults: defaults,
	})
	if err != nil {
		t.Fatal(err)
	}
	if result.Next != "response" || result.NewMachine == nil || !*result.NewMachine || result.Mode != "setup" {
		t.Fatalf("result = %#v", result)
	}
	if keys := opKeys(result.Config); !reflect.DeepEqual(keys, []string{"base", "added"}) {
		t.Fatalf("config keys = %#v", keys)
	}

	result, err = HandleState(StateRequest{
		Phase: "config", Reference: reference, Attempt: opDict(opField("added", opString("saved"))),
		Defaults: defaults, Installer: true,
	})
	if err != nil {
		t.Fatal(err)
	}
	if *result.NewMachine || result.Mode != "installer" {
		t.Fatalf("installer result = %#v", result)
	}
	added, _ := result.Config.Field("added")
	if added.Text != "saved" {
		t.Fatalf("added = %#v", added)
	}
}

func TestStateResponsePreservesOrderValuesAndUniqueChanges(t *testing.T) {
	arbitrary := opDict(
		opField("integer", opInt("9007199254740993")),
		opField("nested", opList(&ConfigValue{Kind: "null"}, opBool(false))),
	)
	result, err := HandleState(StateRequest{
		Phase: "response", Stage: "handoff", Mode: "installer", NewMachine: true,
		Config: arbitrary, Reference: opDict(), Budget: opDict(), Error: opString("failure"),
		Disks: opList(), RigDefaults: opDict(), DataWiped: opDict(), Handoff: arbitrary,
		SavedRole: &ConfigValue{Kind: "null"}, NodeProbe: arbitrary,
		Changes:        opList(opString("first"), opString("same"), opBool(true)),
		Remembered:     opList(opString("same"), opString("last"), opInt("1")),
		InstallAttempt: opDict(), AuthMode: opString("auto"), RestoreEnabled: opBool(true),
	})
	if err != nil {
		t.Fatal(err)
	}
	wantKeys := []string{
		"stage", "mode", "config", "reference", "new_machine", "disk_budget", "error",
		"disks", "rig_defaults", "data_wiped", "handoff", "saved_role", "node_probe",
		"config_changes", "install_attempt", "auth_mode", "restore_enabled",
	}
	if result.Next != "ready" || !reflect.DeepEqual(opKeys(result.Body), wantKeys) {
		t.Fatalf("body keys = %#v", opKeys(result.Body))
	}
	config, _ := result.Body.Field("config")
	if !config.Equal(arbitrary) {
		t.Fatalf("config = %#v", config)
	}
	changes, _ := result.Body.Field("config_changes")
	if got := stateKinds(changes); !reflect.DeepEqual(got, []string{"str:first", "str:same", "bool:true", "str:last"}) {
		t.Fatalf("changes = %#v", got)
	}
}

func TestStateResponseRejectsUnhashableChanges(t *testing.T) {
	_, err := HandleState(StateRequest{
		Phase: "response", Changes: opList(opDict()), Remembered: opList(),
	})
	var typeError configTypeError
	if err == nil || !strings.Contains(err.Error(), "unhashable type: 'dict'") || !reflect.TypeOf(err).AssignableTo(reflect.TypeOf(typeError)) {
		t.Fatalf("error = %T %v", err, err)
	}
}

func TestRunStateReportsProtocolErrorsAndContinues(t *testing.T) {
	request := StateRequest{
		Phase: "config", Reference: opDict(), Attempt: opDict(), Defaults: opDict(),
	}
	raw, err := json.Marshal(request)
	if err != nil {
		t.Fatal(err)
	}
	input := append([]byte("{\"phase\":\"unknown\"}\n"), append(raw, '\n')...)
	var output bytes.Buffer
	if err := RunState(bytes.NewReader(input), &output); err != nil {
		t.Fatal(err)
	}
	lines := strings.Split(strings.TrimSpace(output.String()), "\n")
	if len(lines) != 2 || !strings.Contains(lines[0], `"kind":"ValueError"`) || !strings.Contains(lines[1], `"ok":true`) {
		t.Fatalf("output = %q", output.String())
	}
}

func stateTexts(value *ConfigValue) []string {
	result := make([]string, len(value.Items))
	for index, item := range value.Items {
		result[index] = item.Text
	}
	return result
}

func stateKinds(value *ConfigValue) []string {
	result := make([]string, 0, len(value.Items))
	for _, item := range value.Items {
		switch item.Kind {
		case "str", "int":
			result = append(result, item.Kind+":"+item.Text)
		case "bool":
			if item.Bool {
				result = append(result, "bool:true")
			} else {
				result = append(result, "bool:false")
			}
		}
	}
	return result
}
