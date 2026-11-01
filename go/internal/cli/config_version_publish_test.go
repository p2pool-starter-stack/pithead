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

func TestConfigVersionPublishProtocol(t *testing.T) {
	path := filepath.Join(t.TempDir(), "config.json")
	raw := `{"name":"rig"}`
	if err := os.WriteFile(path, []byte(raw), 0o640); err != nil {
		t.Fatal(err)
	}
	frame := raw + "\x00" + path + "\x002.1.0\x000\x00"
	var output bytes.Buffer
	if err := configVersion(nil, strings.NewReader(frame), &output); err != nil {
		t.Fatal(err)
	}
	if output.Len() != 0 {
		t.Fatalf("output = %q", output.String())
	}
	want := "{\n  \"name\": \"rig\",\n  \"config_version\": \"2.1.0\"\n}\n"
	if content, err := os.ReadFile(path); err != nil || string(content) != want {
		t.Fatalf("content = %q, %v", content, err)
	}
}

func TestConfigVersionPublishRefusalsPreserveTarget(t *testing.T) {
	directory := t.TempDir()
	path := filepath.Join(directory, "config.json")
	raw := `{"name":"rig"}`
	good := raw + "\x00" + path + "\x002.1.0\x000\x00"
	tests := []struct {
		name  string
		args  []string
		input string
	}{
		{"arguments", []string{"extra"}, good},
		{"empty", nil, ""},
		{"truncated", nil, strings.TrimSuffix(good, "\x00")},
		{"trailing", nil, good + "extra\x00"},
		{"producer", nil, strings.TrimSuffix(good, "0\x00") + "1\x00"},
		{"extra field", nil, raw + "\x00" + path + "\x002.1.0\x00extra\x000\x00"},
		{"invalid json", nil, `{"value":1.5}` + "\x00" + path + "\x002.1.0\x000\x00"},
		{"invalid version", nil, raw + "\x00" + path + "\x002.1\x000\x00"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if err := os.WriteFile(path, []byte("old\n"), 0o600); err != nil {
				t.Fatal(err)
			}
			before, err := os.Lstat(path)
			if err != nil {
				t.Fatal(err)
			}
			err = configVersionPublish(test.args, strings.NewReader(test.input))
			var status *ExitError
			if !errors.As(err, &status) || status.Code != 125 {
				t.Fatalf("status = %v", err)
			}
			after, statErr := os.Lstat(path)
			if statErr != nil || !os.SameFile(before, after) {
				t.Fatalf("target changed: %v", statErr)
			}
			if content, readErr := os.ReadFile(path); readErr != nil || string(content) != "old\n" {
				t.Fatalf("content = %q, %v", content, readErr)
			}
			matches, globErr := filepath.Glob(path + ".version.*")
			if globErr != nil || len(matches) != 0 {
				t.Fatalf("temporary files = %v, %v", matches, globErr)
			}
		})
	}
	var status *ExitError
	if err := configVersionPublish(nil, versionPublishFailedReader{}); !errors.As(err, &status) || status.Code != 125 {
		t.Fatalf("read failure = %v", err)
	}
}

type versionPublishFailedReader struct{}

func (versionPublishFailedReader) Read([]byte) (int, error) { return 0, io.ErrUnexpectedEOF }
