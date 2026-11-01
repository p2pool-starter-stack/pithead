package cli

import (
	"bytes"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestConfigCredentialsPublishProtocol(t *testing.T) {
	path := filepath.Join(t.TempDir(), "config.json")
	raw := `{"monero":{}}`
	if err := os.WriteFile(path, []byte(raw), 0o640); err != nil {
		t.Fatal(err)
	}
	frame := raw + "\x00" + path + "\x00user\x00pass\x000\x00"
	var output bytes.Buffer
	if err := configPersistence([]string{"credentials", "publish"}, strings.NewReader(frame), &output); err != nil {
		t.Fatal(err)
	}
	if output.Len() != 0 {
		t.Fatalf("output = %q", output.String())
	}
	want := "{\n  \"monero\": {\n    \"node_username\": \"user\",\n    \"node_password\": \"pass\"\n  }\n}\n"
	if content, err := os.ReadFile(path); err != nil || string(content) != want {
		t.Fatalf("content = %q, %v", content, err)
	}
}

func TestConfigCredentialsPublishRefusalsPreserveTarget(t *testing.T) {
	directory := t.TempDir()
	path := filepath.Join(directory, "config.json")
	raw := `{"monero":{}}`
	good := raw + "\x00" + path + "\x00user\x00pass\x000\x00"
	tests := []struct {
		name  string
		args  []string
		input string
	}{
		{"old extra argument", []string{"credentials", "extra"}, good},
		{"truncated", []string{"credentials", "publish"}, strings.TrimSuffix(good, "\x00")},
		{"trailing", []string{"credentials", "publish"}, good + "extra\x00"},
		{"producer", []string{"credentials", "publish"}, strings.TrimSuffix(good, "0\x00") + "1\x00"},
		{"extra field", []string{"credentials", "publish"}, raw + "\x00" + path + "\x00user\x00pass\x00extra\x000\x00"},
		{"unsupported", []string{"credentials", "publish"}, `{"value":1.5}` + "\x00" + path + "\x00user\x00pass\x000\x00"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if err := os.WriteFile(path, []byte("old\n"), 0o640); err != nil {
				t.Fatal(err)
			}
			before, err := os.Lstat(path)
			if err != nil {
				t.Fatal(err)
			}
			var output bytes.Buffer
			err = configPersistence(test.args, strings.NewReader(test.input), &output)
			var status *ExitError
			if !errors.As(err, &status) || status.Code != 125 || output.Len() != 0 {
				t.Fatalf("result = %v, %q", err, output.String())
			}
			after, statErr := os.Lstat(path)
			if statErr != nil || !os.SameFile(before, after) {
				t.Fatalf("target changed: %v", statErr)
			}
			if _, stageErr := os.Lstat(path + ".tmp"); !errors.Is(stageErr, os.ErrNotExist) {
				t.Fatalf("stage remains: %v", stageErr)
			}
		})
	}
	if err := configCredentialsPublish(credentialsPublishFailedReader{}); exitStatus(err) != 125 {
		t.Fatalf("read failure = %v", err)
	}
}

type credentialsPublishFailedReader struct{}

func (credentialsPublishFailedReader) Read([]byte) (int, error) { return 0, io.ErrUnexpectedEOF }
