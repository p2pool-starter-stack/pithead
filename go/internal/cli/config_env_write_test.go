package cli

import (
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestConfigEnvWriteProtocol(t *testing.T) {
	path := filepath.Join(t.TempDir(), ".env")
	if err := configEnvWrite(nil, strings.NewReader(path+"\x00A=1\nB=2\x000\x00")); err != nil {
		t.Fatal(err)
	}
	content, err := os.ReadFile(path)
	if err != nil || string(content) != "A=1\nB=2\n" {
		t.Fatalf("content = %q, %v", content, err)
	}
}

func TestConfigEnvWriteRefusalsPreserveTarget(t *testing.T) {
	directory := t.TempDir()
	path := filepath.Join(directory, ".env")
	good := path + "\x00new\x000\x00"
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
		{"extra field", nil, path + "\x00new\x00extra\x000\x00"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if err := os.WriteFile(path, []byte("old\n"), 0o600); err != nil {
				t.Fatal(err)
			}
			err := configEnvWrite(test.args, strings.NewReader(test.input))
			var status *ExitError
			if !errors.As(err, &status) || status.Code != 125 {
				t.Fatalf("status = %v", err)
			}
			if content, err := os.ReadFile(path); err != nil || string(content) != "old\n" {
				t.Fatalf("target = %q, %v", content, err)
			}
		})
	}
	var status *ExitError
	if err := configEnvWrite(nil, envWriteFailedReader{}); !errors.As(err, &status) || status.Code != 125 {
		t.Fatalf("read failure = %v", err)
	}
}

type envWriteFailedReader struct{}

func (envWriteFailedReader) Read([]byte) (int, error) { return 0, io.ErrUnexpectedEOF }
