package cli

import (
	"bytes"
	"errors"
	"io"
	"strings"
	"testing"
)

func TestConfigEnvResourcesProtocol(t *testing.T) {
	tests := []struct {
		name   string
		args   []string
		input  string
		output string
		code   int
	}{
		{"threads", []string{"threads"}, "7\x000\x00", "5\x00", 0},
		{"peers-valid", []string{"peers"}, "0008\x000\x00", "true\x00", 0},
		{"peers-invalid", []string{"peers"}, "7\x000\x00", "false\x00", 0},
		{"arguments", nil, "7\x000\x00", "", 125},
		{"unknown", []string{"other"}, "7\x000\x00", "", 125},
		{"empty", []string{"threads"}, "", "", 125},
		{"unterminated", []string{"threads"}, "7\x000", "", 125},
		{"extra", []string{"threads"}, "7\x000\x00extra\x00", "", 125},
		{"producer-failed", []string{"threads"}, "7\x001\x00", "", 125},
		{"producer-status-invalid", []string{"threads"}, "7\x0000\x00", "", 125},
		{"unsupported-threads", []string{"threads"}, "08\x000\x00", "", 125},
		{"overflow-peers", []string{"peers"}, "9223372036854775808\x000\x00", "", 125},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			var output bytes.Buffer
			err := configEnvResources(test.args, strings.NewReader(test.input), &output)
			if test.code == 0 {
				if err != nil || output.String() != test.output {
					t.Fatalf("got %v and %q; want nil and %q", err, output.String(), test.output)
				}
				return
			}
			var status *ExitError
			if !errors.As(err, &status) || status.Code != test.code || output.Len() != 0 {
				t.Fatalf("got %v and %q; want code %d and empty output", err, output.Bytes(), test.code)
			}
		})
	}
}

func TestConfigEnvResourcesIOFailure(t *testing.T) {
	err := configEnvResources([]string{"threads"}, resourceFailedReader{}, io.Discard)
	var status *ExitError
	if !errors.As(err, &status) || status.Code != 125 {
		t.Fatalf("read failure = %v", err)
	}
	err = configEnvResources([]string{"threads"}, strings.NewReader("7\x000\x00"), resourceFailedWriter{})
	if !errors.As(err, &status) || status.Code != 125 {
		t.Fatalf("write failure = %v", err)
	}
	err = configEnvResources([]string{"threads"}, strings.NewReader("7\x000\x00"), resourceShortWriter{})
	if !errors.As(err, &status) || status.Code != 125 {
		t.Fatalf("short write = %v", err)
	}
}

type resourceFailedReader struct{}

func (resourceFailedReader) Read([]byte) (int, error) { return 0, io.ErrUnexpectedEOF }

type resourceFailedWriter struct{}

func (resourceFailedWriter) Write([]byte) (int, error) { return 0, io.ErrClosedPipe }

type resourceShortWriter struct{}

func (resourceShortWriter) Write(value []byte) (int, error) { return len(value) - 1, nil }
