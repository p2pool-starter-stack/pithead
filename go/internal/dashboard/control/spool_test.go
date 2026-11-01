package control

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

func TestWritePublishesRawBytesPrivately(t *testing.T) {
	directory := t.TempDir()
	raw := []byte("{\"snowman\": \"\\u2603\", \"value\": NaN}")
	value, err := Process(Request{Operation: "control-write", Directory: directory, ID: "abc", Data: raw})
	if err != nil || value != "abc" {
		t.Fatalf("%#v, %v", value, err)
	}
	path := filepath.Join(directory, "abc.json")
	written, err := os.ReadFile(path)
	if err != nil || !bytes.Equal(written, raw) {
		t.Fatalf("%q, %v", written, err)
	}
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if runtime.GOOS != "windows" && info.Mode().Perm() != 0o600 {
		t.Fatalf("mode %o", info.Mode().Perm())
	}
	entries, err := os.ReadDir(directory)
	if err != nil || len(entries) != 1 || entries[0].Name() != "abc.json" {
		t.Fatalf("%v, %v", entries, err)
	}
}

func TestWriteDistinguishesEmptyAndMissingID(t *testing.T) {
	directory := t.TempDir()
	input := strings.NewReader(`{"operation":"control-write","directory":` + mustJSON(t, directory) + `,"id":"","data":"eA=="}` + "\n" + `{"operation":"control-write","directory":` + mustJSON(t, directory) + `,"data":"eQ=="}` + "\n")
	var output bytes.Buffer
	if err := Run(input, &output); err != nil {
		t.Fatal(err)
	}
	lines := strings.Split(strings.TrimSpace(output.String()), "\n")
	if len(lines) != 2 {
		t.Fatal(output.String())
	}
	var empty, missing map[string]any
	if err := json.Unmarshal([]byte(lines[0]), &empty); err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal([]byte(lines[1]), &missing); err != nil {
		t.Fatal(err)
	}
	if empty["ok"] != true || empty["value"] != "" {
		t.Fatal(empty)
	}
	if data, err := os.ReadFile(filepath.Join(directory, ".json")); err != nil || string(data) != "x" {
		t.Fatalf("%q, %v", data, err)
	}
	if missing["ok"] != false || missing["error"].(map[string]any)["kind"] != "KeyError" {
		t.Fatal(missing)
	}
}

func TestWriteFailureCleansTempAndDoesNotCreateDirectory(t *testing.T) {
	directory := t.TempDir()
	if err := os.Mkdir(filepath.Join(directory, "abc.json"), 0o700); err != nil {
		t.Fatal(err)
	}
	_, err := Process(Request{Operation: "control-write", Directory: directory, ID: "abc", Request: json.RawMessage(`{"id":"abc"}`)})
	if err == nil {
		t.Fatal("publication failure accepted")
	}
	entries, readErr := os.ReadDir(directory)
	if readErr != nil || len(entries) != 1 || entries[0].Name() != "abc.json" {
		t.Fatalf("%v, %v", entries, readErr)
	}
	missing := filepath.Join(directory, "missing")
	_, err = Process(Request{Operation: "control-write", Directory: missing, ID: "abc", Data: []byte("x")})
	if err == nil || !strings.Contains(err.Error(), "no such file") {
		t.Fatal(err)
	}
	if _, statErr := os.Stat(missing); !os.IsNotExist(statErr) {
		t.Fatal(statErr)
	}
}

func TestStageAndPublish(t *testing.T) {
	directory := t.TempDir()
	value, err := Process(Request{Operation: "control-stage", Directory: directory, ID: "abc", Data: []byte("raw")})
	if err != nil {
		t.Fatal(err)
	}
	temp := value.(string)
	if filepath.Dir(temp) != directory || !strings.HasPrefix(filepath.Base(temp), ".abc.") || !strings.HasSuffix(temp, ".tmp") {
		t.Fatal(temp)
	}
	if _, err := Process(Request{Operation: "control-publish", Directory: directory, ID: "abc", Temp: temp}); err != nil {
		t.Fatal(err)
	}
	if data, err := os.ReadFile(filepath.Join(directory, "abc.json")); err != nil || string(data) != "raw" {
		t.Fatalf("%q, %v", data, err)
	}
	outside := filepath.Join(t.TempDir(), ".abc.bad.tmp")
	if err := os.WriteFile(outside, []byte("bad"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := Process(Request{Operation: "control-publish", Directory: directory, ID: "abc", Temp: outside}); err == nil {
		t.Fatal("outside temp accepted")
	}
}

func TestRunReportsStructuredErrorsAndContinues(t *testing.T) {
	directory := filepath.Join(t.TempDir(), "absent")
	input := strings.NewReader("not json\n" + `{"operation":"control-write","directory":` + mustJSON(t, directory) + `,"id":"abc","data":"eA=="}` + "\n" + `{"operation":"control-validate-worker","changes":{"DONATION":1}}` + "\n")
	var output bytes.Buffer
	if err := Run(input, &output); err != nil {
		t.Fatal(err)
	}
	lines := strings.Split(strings.TrimSpace(output.String()), "\n")
	if len(lines) != 3 {
		t.Fatal(output.String())
	}
	var replies []map[string]any
	for _, line := range lines {
		var reply map[string]any
		if err := json.Unmarshal([]byte(line), &reply); err != nil {
			t.Fatal(err)
		}
		replies = append(replies, reply)
	}
	if replies[0]["ok"] != false || replies[0]["error"].(map[string]any)["kind"] != "ValueError" {
		t.Fatal(replies[0])
	}
	writeError := replies[1]["error"].(map[string]any)
	if replies[1]["ok"] != false || writeError["kind"] != "OSError" || writeError["errno"].(float64) == 0 {
		t.Fatal(replies[1])
	}
	if replies[2]["ok"] != true || replies[2]["value"] != "" {
		t.Fatal(replies[2])
	}
}

func mustJSON(t *testing.T, value string) string {
	t.Helper()
	data, err := json.Marshal(value)
	if err != nil {
		t.Fatal(err)
	}
	return string(data)
}
