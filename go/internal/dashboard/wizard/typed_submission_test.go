package wizard

import (
	"bytes"
	"encoding/json"
	"errors"
	"reflect"
	"strings"
	"testing"
)

func TestTypedSubmissionKeepIgnoresCraftedConfig(t *testing.T) {
	result, err := HandleTypedSubmission(TypedSubmissionRequest{
		Phase:     "keep",
		Fields:    typedFields(map[string]string{"disk": "disk-a", "confirm": "disk-a", "role": "rig"}),
		Disks:     []map[string]any{{"name": "disk-a", "state": "pithead-with-data"}},
		Config:    typedDict("monero", typedDict("clearnet_initial_sync", &ConfigValue{Kind: "bool", Bool: true})),
		Changes:   configStrings([]string{"crafted"}),
		Install:   map[string]any{"disk": "other", "wipe": "all"},
		ProbeOK:   true,
		Installer: true,
	})
	if err != nil {
		t.Fatal(err)
	}
	if result.Status != 200 || result.Next != "" {
		t.Fatalf("keep result = %#v", result)
	}
	want := []string{"clear-host", "clear-sidecars", "text:submission-staging", "json:install-attempt.json", "text:install-request", "text:submission-active"}
	if got := typedActionNames(result.Actions); !reflect.DeepEqual(got, want) {
		t.Fatalf("actions = %v, want %v", got, want)
	}
	if got := result.Actions[3].Pairs; !reflect.DeepEqual(got, [][2]any{{"disk", "disk-a"}, {"wipe", "keep"}}) {
		t.Fatalf("install attempt = %#v", got)
	}
}

func TestTypedSubmissionKeepInventoryAndConfirmation(t *testing.T) {
	_, err := HandleTypedSubmission(TypedSubmissionRequest{Phase: "keep", Disks: []map[string]any{{"state": "pithead-with-data"}}})
	var key formKeyError
	if !errors.As(err, &key) || key.key != "name" {
		t.Fatalf("missing name error = %#v", err)
	}

	request := TypedSubmissionRequest{
		Phase:  "keep",
		Fields: typedFields(map[string]string{"disk": "disk-a", "confirm": "wrong"}),
		Disks: []map[string]any{
			{"name": "disk-a", "state": "wrong"},
			{"name": "disk-a", "state": "pithead-with-data"},
		},
	}
	result, err := HandleTypedSubmission(request)
	if err != nil || result.Status != 400 {
		t.Fatalf("confirmation result = %#v, %v", result, err)
	}
	if got := result.Body.(map[string]string)["error"]; got != "type disk-a exactly to confirm" {
		t.Fatalf("confirmation error = %q", got)
	}

	request.Fields["disk"] = Field{Text: "missing"}
	result, err = HandleTypedSubmission(request)
	if err != nil || result.Body.(map[string]string)["error"] != "choose a disk from the list" {
		t.Fatalf("unknown disk result = %#v, %v", result, err)
	}
}

func TestTypedSubmissionKeepRoutesNonInstallDisk(t *testing.T) {
	result, err := HandleTypedSubmission(TypedSubmissionRequest{
		Phase:  "keep",
		Fields: typedFields(map[string]string{"disk": "disk-a", "confirm": "disk-a", "role": "rig"}),
		Disks:  []map[string]any{{"name": "disk-a", "state": "empty"}},
	})
	if err != nil || result.Next != "rig" || len(result.Actions) != 0 {
		t.Fatalf("result = %#v, %v", result, err)
	}
}

func TestTypedSubmissionPreparedAuthMode(t *testing.T) {
	for _, test := range []struct {
		mode string
		want []string
	}{
		{"auto", []string{"clear-sidecars", "text:auth-mode"}},
		{"set", []string{"clear-sidecars", "text:auth-mode"}},
		{"none", []string{"clear-sidecars", "text:auth-mode"}},
		{"crafted", []string{"clear-sidecars"}},
	} {
		result, err := HandleTypedSubmission(TypedSubmissionRequest{Phase: "prepared", Fields: typedFields(map[string]string{"auth_mode": test.mode})})
		if err != nil || result.Next != "install" || !reflect.DeepEqual(typedActionNames(result.Actions), test.want) {
			t.Fatalf("mode %q result = %#v, %v", test.mode, result, err)
		}
	}
}

func TestTypedSubmissionInstallValidation(t *testing.T) {
	request := TypedSubmissionRequest{
		Phase:     "install",
		Installer: true,
		Fields:    typedFields(map[string]string{"disk": "disk-a", "confirm": "wrong", "wipe": "all"}),
		Disks:     []map[string]any{{"name": "disk-a", "state": "pithead-with-data"}},
	}
	result, err := HandleTypedSubmission(request)
	if err != nil || result.Status != 400 || result.Body.(map[string]string)["error"] != "type disk-a exactly to confirm" {
		t.Fatalf("validation result = %#v, %v", result, err)
	}

	request.Fields["confirm"] = Field{Text: "disk-a"}
	request.Disks = []map[string]any{{"state": "pithead-with-data"}}
	_, err = HandleTypedSubmission(request)
	var key formKeyError
	if !errors.As(err, &key) || key.key != "name" {
		t.Fatalf("inventory error = %#v", err)
	}

	request.Installer = false
	result, err = HandleTypedSubmission(request)
	if err != nil || result.Next != "probe" || result.Install != nil {
		t.Fatalf("non-installer result = %#v, %v", result, err)
	}
}

func TestTypedSubmissionProbeActionOrder(t *testing.T) {
	report, err := HandleTypedSubmission(TypedSubmissionRequest{Phase: "report", Configured: true})
	if err != nil {
		t.Fatal(err)
	}
	if report.Next != "verdict" || !reflect.DeepEqual(typedActionNames(report.Actions), []string{"report"}) {
		t.Fatalf("report = %#v", report)
	}

	rejected, err := HandleTypedSubmission(TypedSubmissionRequest{Phase: "verdict"})
	if err != nil {
		t.Fatal(err)
	}
	wantRejected := []string{"remember", "attempt", "remove:install-request"}
	if got := typedActionNames(rejected.Actions); rejected.Next != "failure" || !reflect.DeepEqual(got, wantRejected) {
		t.Fatalf("rejected = %v next %q", got, rejected.Next)
	}

	accepted, err := HandleTypedSubmission(TypedSubmissionRequest{
		Phase: "verdict", ProbeOK: true, Install: map[string]any{"disk": "disk-a", "wipe": "data"},
	})
	if err != nil {
		t.Fatal(err)
	}
	wantAccepted := []string{
		"text:submission-staging", "remember", "attempt", "config", "json:install-attempt.json", "text:install-request", "text:submission-active",
	}
	if got := typedActionNames(accepted.Actions); accepted.Next != "accepted" || !reflect.DeepEqual(got, wantAccepted) {
		t.Fatalf("accepted = %v next %q", got, accepted.Next)
	}
}

func TestTypedSubmissionAcceptedWarningRequiresTrueBool(t *testing.T) {
	config := typedDict(
		"monero", typedDict("clearnet_initial_sync", &ConfigValue{Kind: "bool", Bool: true}),
		"tari", typedDict("clearnet_initial_sync", &ConfigValue{Kind: "int", Text: "1"}),
	)
	result, err := HandleTypedSubmission(TypedSubmissionRequest{Phase: "accepted", Config: config})
	if err != nil {
		t.Fatal(err)
	}
	raw, err := json.Marshal(result)
	if err != nil {
		t.Fatal(err)
	}
	want := `{"status":200,"body":{"status":"accepted","config_changes":["list",[]],"warning":"Fast sync exposes your IP address to the Monero network until the initial sync finishes."}}`
	if string(raw) != want {
		t.Fatalf("accepted JSON = %s, want %s", raw, want)
	}
}

func TestTypedSubmissionAcceptedPreservesSurrogateChange(t *testing.T) {
	surrogate := string([]byte{0xed, 0xa0, 0x80})
	result, err := HandleTypedSubmission(TypedSubmissionRequest{
		Phase: "accepted", Changes: configStrings([]string{surrogate + " removed"}),
	})
	if err != nil {
		t.Fatal(err)
	}
	raw, err := json.Marshal(result)
	if err != nil {
		t.Fatal(err)
	}
	var decoded struct {
		Body struct {
			ConfigChanges ConfigValue `json:"config_changes"`
		} `json:"body"`
	}
	if err := json.Unmarshal(raw, &decoded); err != nil {
		t.Fatal(err)
	}
	if len(decoded.Body.ConfigChanges.Items) != 1 || decoded.Body.ConfigChanges.Items[0].Text != surrogate+" removed" {
		t.Fatalf("change lost surrogate bytes: %x", raw)
	}
}

func TestTypedSubmissionFailurePreservesTypedDetail(t *testing.T) {
	surrogate := string([]byte{0xed, 0xa0, 0x80})
	failure := typedDict("detail", &ConfigValue{Kind: "str", Text: surrogate}, "code", &ConfigValue{Kind: "int", Text: "17"})
	result, err := HandleTypedSubmission(TypedSubmissionRequest{Phase: "failure", Failure: failure})
	if err != nil {
		t.Fatal(err)
	}
	raw, err := json.Marshal(result)
	if err != nil {
		t.Fatal(err)
	}
	var decoded struct {
		Body struct {
			Error ConfigValue `json:"error"`
		} `json:"body"`
	}
	if err := json.Unmarshal(raw, &decoded); err != nil {
		t.Fatal(err)
	}
	if !decoded.Body.Error.Equal(failure) {
		t.Fatalf("failure detail changed: %x", raw)
	}
}

func TestRunTypedSubmissionJSONLinesAndErrors(t *testing.T) {
	input := strings.NewReader("{\"phase\":\"failure\",\"failure\":[\"str\",\"probe failed\"]}\n{\"phase\":\"unknown\"}\n{\n")
	var output bytes.Buffer
	if err := RunTypedSubmission(input, &output); err != nil {
		t.Fatal(err)
	}
	lines := strings.Split(strings.TrimSpace(output.String()), "\n")
	if len(lines) != 3 {
		t.Fatalf("protocol output = %q", output.String())
	}
	if lines[0] != `{"ok":true,"value":{"status":400,"body":{"error":["str","probe failed"]},"include_report":true}}` {
		t.Fatalf("failure response = %s", lines[0])
	}
	if !strings.Contains(lines[1], `"kind":"ValueError"`) || !strings.Contains(lines[1], "unsupported typed wizard submission phase") {
		t.Fatalf("phase error = %s", lines[1])
	}
	if !strings.Contains(lines[2], `"kind":"OSError"`) || !strings.Contains(lines[2], "unexpected EOF") {
		t.Fatalf("decode error = %s", lines[2])
	}
}

func typedFields(values map[string]string) map[string]Field {
	fields := make(map[string]Field, len(values))
	for name, value := range values {
		fields[name] = Field{Text: value}
	}
	return fields
}

func typedDict(values ...any) *ConfigValue {
	fields := make([]ConfigField, 0, len(values)/2)
	for index := 0; index < len(values); index += 2 {
		fields = append(fields, ConfigField{Key: values[index].(string), Value: values[index+1].(*ConfigValue)})
	}
	return &ConfigValue{Kind: "dict", Fields: fields}
}

func typedActionNames(actions []SubmissionAction) []string {
	names := make([]string, len(actions))
	for index, action := range actions {
		names[index] = action.Operation
		if action.Name != "" {
			names[index] += ":" + action.Name
		}
	}
	return names
}
