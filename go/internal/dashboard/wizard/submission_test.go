package wizard

import (
	"bytes"
	"encoding/json"
	"errors"
	"strings"
	"testing"
)

func TestRigSubmissionDefersInstallAndPreservesJSONOrder(t *testing.T) {
	fields := map[string]Field{
		"rig_pool":     {Text: "pool.example:²", Digit: true},
		"rig_worker":   {Text: "worker-a"},
		"rig_password": {Text: "secret"},
		"disk":         {Text: "disk-a"},
		"confirm":      {Text: "disk-a"},
		"wipe":         {Text: "all"},
	}
	start, err := HandleSubmission(SubmissionRequest{Operation: "rig", Phase: "start", Fields: fields})
	if err != nil {
		t.Fatal(err)
	}
	if start.Next != "install" || len(start.Actions) != 0 {
		t.Fatalf("start=%#v", start)
	}

	published, err := HandleSubmission(SubmissionRequest{
		Operation: "rig", Phase: "publish", Fields: fields, Installer: true,
		Disks: []map[string]any{{"name": "disk-a", "state": "pithead-with-data"}},
	})
	if err != nil {
		t.Fatal(err)
	}
	wantOperations := []string{"clear-host", "clear-sidecars", "text", "text", "json", "json", "text", "text"}
	if len(published.Actions) != len(wantOperations) {
		t.Fatalf("actions=%#v", published.Actions)
	}
	for index, operation := range wantOperations {
		if published.Actions[index].Operation != operation {
			t.Fatalf("action %d=%#v", index, published.Actions[index])
		}
	}
	wantRig := [][2]any{{"pool", "pool.example:²"}, {"worker", "worker-a"}, {"stratum_password", "secret"}}
	assertJSONEqual(t, published.Actions[4].Pairs, wantRig)
	wantInstall := [][2]any{{"disk", "disk-a"}, {"wipe", "all"}}
	assertJSONEqual(t, published.Actions[5].Pairs, wantInstall)
	if published.Actions[6].Name != "install-request" || published.Actions[6].Text != "disk-a\tall" || published.Status != 200 {
		t.Fatalf("published=%#v", published)
	}
}

func TestRigSubmissionRejectsPoolBeforeInstall(t *testing.T) {
	result, err := HandleSubmission(SubmissionRequest{
		Operation: "rig", Phase: "start", Installer: true,
		Fields: map[string]Field{"rig_pool": {Text: ":3333", Digit: true}},
	})
	if err != nil {
		t.Fatal(err)
	}
	assertSubmissionError(t, result, 400, "enter the pool address as host:port — a Pithead answers on port 3333")
	if len(result.Actions) != 0 || result.Next != "" {
		t.Fatalf("result=%#v", result)
	}
}

func TestRigSubmissionStickSkipsDiskValidation(t *testing.T) {
	result, err := HandleSubmission(SubmissionRequest{
		Operation: "rig", Phase: "publish", Installer: true,
		Fields: map[string]Field{
			"rig_pool": {Text: "pool:3333", Digit: true},
			"disk":     {Text: "usb"},
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	if result.Status != 200 || len(result.Actions) != 6 {
		t.Fatalf("result=%#v", result)
	}
}

func TestRestoreSubmissionPhasesAndPlacement(t *testing.T) {
	start, err := HandleSubmission(SubmissionRequest{Operation: "restore", Phase: "start", Upload: true})
	if err != nil {
		t.Fatal(err)
	}
	if start.Next != "read-upload" || len(start.Actions) != 2 || start.Actions[0].Operation != "clear-host" || start.Actions[1].Name != "stick" {
		t.Fatalf("start=%#v", start)
	}
	missing, err := HandleSubmission(SubmissionRequest{Operation: "restore", Phase: "start"})
	if err != nil {
		t.Fatal(err)
	}
	assertSubmissionError(t, missing, 400, "choose a backup archive to upload")
	if len(missing.Actions) != 2 {
		t.Fatalf("missing actions=%#v", missing.Actions)
	}

	validated, err := HandleSubmission(SubmissionRequest{Operation: "restore", Phase: "validate", Size: 64 << 20, Limit: 64 << 20})
	if err != nil || validated.Next != "passphrase" {
		t.Fatalf("validated=%#v err=%v", validated, err)
	}
	tooLarge, err := HandleSubmission(SubmissionRequest{Operation: "restore", Phase: "validate", Size: 64<<20 + 1, Limit: 64 << 20})
	if err != nil {
		t.Fatal(err)
	}
	assertSubmissionError(t, tooLarge, 400, "archive too large (max 64 MB) — a Pithead backup holds only config, keys and the dashboard database, never the blockchains")
	passphrase, err := HandleSubmission(SubmissionRequest{Operation: "restore", Phase: "passphrase", PassphraseBytes: 4096})
	if err != nil || passphrase.Next != "install" {
		t.Fatalf("passphrase=%#v err=%v", passphrase, err)
	}
	tooLong, err := HandleSubmission(SubmissionRequest{Operation: "restore", Phase: "passphrase", PassphraseBytes: 4097})
	if err != nil {
		t.Fatal(err)
	}
	assertSubmissionError(t, tooLong, 400, "restore passphrase is too large")

	published, err := HandleSubmission(SubmissionRequest{Operation: "restore", Phase: "publish", Encrypted: false})
	if err != nil {
		t.Fatal(err)
	}
	want := []struct {
		operation string
		name      string
		volatile  bool
	}{
		{"clear-sidecars", "", false},
		{"remove", "last-attempt.json", false},
		{"text", "submission-staging", false},
		{"passphrase", "restore-passphrase", true},
		{"archive", "restore-archive", true},
		{"text", "submission-active", false},
	}
	if len(published.Actions) != len(want) {
		t.Fatalf("actions=%#v", published.Actions)
	}
	for index, expected := range want {
		action := published.Actions[index]
		if action.Operation != expected.operation || action.Name != expected.name || action.Volatile != expected.volatile {
			t.Fatalf("action %d=%#v", index, action)
		}
	}
}

func TestRestorePublishValidatesInstallBeforeActions(t *testing.T) {
	result, err := HandleSubmission(SubmissionRequest{
		Operation: "restore", Phase: "publish", Installer: true,
		Fields: map[string]Field{"disk": {Text: "missing"}, "confirm": {Text: "missing"}},
	})
	if err != nil {
		t.Fatal(err)
	}
	assertSubmissionError(t, result, 400, "choose a disk from the list")
	if len(result.Actions) != 0 {
		t.Fatalf("actions=%#v", result.Actions)
	}
}

func TestSubmissionInstallKeyErrorsPropagate(t *testing.T) {
	for _, request := range []SubmissionRequest{
		{
			Operation: "rig", Phase: "publish", Installer: true,
			Fields: map[string]Field{
				"rig_pool": {Text: "pool:3333", Digit: true},
				"disk":     {Text: "disk-a"},
				"confirm":  {Text: "disk-a"},
			},
			Disks: []map[string]any{{"state": "empty"}},
		},
		{
			Operation: "restore", Phase: "publish", Installer: true,
			Fields: map[string]Field{
				"disk":    {Text: "disk-a"},
				"confirm": {Text: "disk-a"},
				"wipe":    {Text: "all"},
			},
			Disks: []map[string]any{{"name": "disk-a"}},
		},
	} {
		result, err := HandleSubmission(request)
		var key formKeyError
		if !errors.As(err, &key) || len(result.Actions) != 0 || result.Status != 0 || result.Body != nil || result.Next != "" {
			t.Fatalf("result=%#v error=%v", result, err)
		}
	}
}

func TestSubmissionFailures(t *testing.T) {
	for _, test := range []struct {
		phase   string
		cleaned bool
		message string
	}{
		{"setup", true, "could not stage the setup submission; submit it again"},
		{"setup", false, "could not stage the setup submission; submit it again; temporary setup files could not be cleared safely"},
		{"restore", true, "could not stage the restore; submit it again"},
		{"restore", false, "could not stage the restore; submit it again; temporary restore files could not be cleared safely"},
	} {
		result, err := HandleSubmission(SubmissionRequest{Operation: "failure", Phase: test.phase, Cleaned: test.cleaned})
		if err != nil {
			t.Fatal(err)
		}
		assertSubmissionError(t, result, 500, test.message)
	}
}

func TestRunSubmissionJSONLines(t *testing.T) {
	input := strings.NewReader("{\"operation\":\"restore\",\"phase\":\"passphrase\",\"passphrase_bytes\":4097}\n{\"operation\":\"unknown\"}\nnot-json\n{\"operation\":\"restore\",\"phase\":\"publish\",\"installer\":true,\"fields\":{\"disk\":{\"text\":\"disk-a\"},\"confirm\":{\"text\":\"disk-a\"}},\"disks\":[{\"state\":\"empty\"}]}\n")
	var output bytes.Buffer
	if err := RunSubmission(input, &output); err != nil {
		t.Fatal(err)
	}
	lines := strings.Split(strings.TrimSpace(output.String()), "\n")
	if len(lines) != 4 {
		t.Fatalf("lines=%d", len(lines))
	}
	first := decodeTerminalResponse(t, lines[0])
	var result SubmissionResult
	if !first.OK || json.Unmarshal(first.Value, &result) != nil || result.Status != 400 {
		t.Fatalf("first=%#v result=%#v", first, result)
	}
	unknown := decodeTerminalResponse(t, lines[1])
	malformed := decodeTerminalResponse(t, lines[2])
	key := decodeTerminalResponse(t, lines[3])
	if unknown.OK || unknown.Error == nil || unknown.Error.Kind != "ValueError" || malformed.OK || malformed.Error == nil || key.OK || key.Error == nil || key.Error.Kind != "KeyError" {
		t.Fatalf("unknown=%#v malformed=%#v key=%#v", unknown, malformed, key)
	}
}

func assertSubmissionError(t *testing.T, result SubmissionResult, status int, message string) {
	t.Helper()
	body, ok := result.Body.(map[string]string)
	if !ok || result.Status != status || body["error"] != message {
		t.Fatalf("result=%#v, want status %d error %q", result, status, message)
	}
}
