package cli

import (
	"bytes"
	"errors"
	"io"
	"strings"
	"testing"
)

func TestConfigEnvMemoryProtocol(t *testing.T) {
	for _, fixture := range []struct {
		name string
		args []string
		raw  string
		want string
		code int
	}{
		{"defaults", []string{"settings"}, "local\x00{}\x000\x00", "auto\x006g\x00", 0},
		{"off", []string{"settings"}, "off\x00{\"tari\":7}\x000\x00", "0m\x006g\x00", 0},
		{"cap", []string{"limit"}, "16384\x006144\x00", "7680m\x00", 0},
		{"floor", []string{"limit"}, "1024\x002048\x00", "2048m\x00", 0},
		{"no-operation", nil, "", "", 125},
		{"unknown-operation", []string{"other"}, "", "", 125},
		{"extra-argument", []string{"limit", "extra"}, "16384\x000\x00", "", 125},
		{"empty-settings", []string{"settings"}, "", "", 125},
		{"missing-footer", []string{"settings"}, "local\x00{}\x00", "", 125},
		{"failed-producer", []string{"settings"}, "local\x00{}\x001\x00", "", 125},
		{"invalid-status", []string{"settings"}, "local\x00{}\x0000\x00", "", 125},
		{"extra-field", []string{"settings"}, "local\x00{}\x000\x00extra\x00", "", 125},
		{"invalid-json", []string{"settings"}, "local\x00{\x000\x00", "", 125},
		{"unsupported-number", []string{"settings"}, "local\x00{\"tari\":{\"mem_limit\":8.0}}\x000\x00", "", 125},
		{"empty-limit", []string{"limit"}, "", "", 125},
		{"missing-terminator", []string{"limit"}, "16384\x000", "", 125},
		{"extra-fact", []string{"limit"}, "16384\x000\x00extra\x00", "", 125},
		{"noncanonical-fact", []string{"limit"}, "016384\x000\x00", "", 125},
	} {
		t.Run(fixture.name, func(t *testing.T) {
			var output bytes.Buffer
			err := configEnvMemory(fixture.args, strings.NewReader(fixture.raw), &output)
			code := 0
			if err != nil {
				var status *ExitError
				if !errors.As(err, &status) {
					t.Fatal(err)
				}
				code = status.Code
			}
			if code != fixture.code || output.String() != fixture.want {
				t.Fatalf("got %d and %q; want %d and %q", code, output.String(), fixture.code, fixture.want)
			}
		})
	}
}

func TestConfigEnvMemoryIOFailure(t *testing.T) {
	err := configEnvMemory([]string{"limit"}, failedMemoryReader{}, io.Discard)
	var status *ExitError
	if !errors.As(err, &status) || status.Code != 125 {
		t.Fatalf("got %v", err)
	}
	err = configEnvMemory([]string{"limit"}, strings.NewReader("16384\x000\x00"), failedMemoryWriter{})
	if !errors.As(err, &status) || status.Code != 125 {
		t.Fatalf("got %v", err)
	}
}

type failedMemoryReader struct{}

func (failedMemoryReader) Read([]byte) (int, error) { return 0, io.ErrUnexpectedEOF }

type failedMemoryWriter struct{}

func (failedMemoryWriter) Write([]byte) (int, error) { return 0, io.ErrClosedPipe }
