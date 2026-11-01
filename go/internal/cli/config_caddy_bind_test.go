package cli

import (
	"bytes"
	"errors"
	"io"
	"strings"
	"testing"
)

func TestConfigCaddyBindProtocol(t *testing.T) {
	for _, test := range []struct {
		name string
		args []string
		raw  string
		want string
		code int
	}{
		{"success", nil, " 172.17.0.1 \x00172.28.0\x003\x00192.168.1.2\x00172.17.0.1\x00fd00::2\x000\x00", "192.168.1.2 fd00::2 127.0.0.1 ::1\x00", 0},
		{"zero", nil, " \x00\x000\x000\x00", "127.0.0.1 ::1\x00", 0},
		{"argument", []string{"extra"}, " \x00\x000\x000\x00", "", 125},
		{"empty", nil, "", "", 125},
		{"missing-terminator", nil, " \x00\x000\x000", "", 125},
		{"bad-count", nil, " \x00\x0000\x000\x00", "", 125},
		{"negative-count", nil, " \x00\x00-1\x000\x00", "", 125},
		{"short-candidates", nil, " \x00\x002\x0010.0.0.2\x000\x00", "", 125},
		{"extra-candidate", nil, " \x00\x000\x0010.0.0.2\x000\x00", "", 125},
		{"producer-failure", nil, " \x00\x000\x001\x00", "", 125},
		{"bad-status", nil, " \x00\x000\x0000\x00", "", 125},
		{"extra-field", nil, " \x00\x000\x000\x00extra\x00", "", 125},
	} {
		t.Run(test.name, func(t *testing.T) {
			var output bytes.Buffer
			err := configCaddyBind(test.args, strings.NewReader(test.raw), &output)
			code := 0
			if err != nil {
				var status *ExitError
				if !errors.As(err, &status) {
					t.Fatal(err)
				}
				code = status.Code
			}
			if code != test.code || output.String() != test.want {
				t.Fatalf("got %d and %q; want %d and %q", code, output.String(), test.code, test.want)
			}
		})
	}
}

func TestConfigCaddyBindIOFailure(t *testing.T) {
	var status *ExitError
	err := configCaddyBind(nil, failedCaddyBindReader{}, io.Discard)
	if !errors.As(err, &status) || status.Code != 125 {
		t.Fatalf("got %v", err)
	}
	err = configCaddyBind(nil, strings.NewReader(" \x00\x000\x000\x00"), failedCaddyBindWriter{})
	if !errors.As(err, &status) || status.Code != 125 {
		t.Fatalf("got %v", err)
	}
}

type failedCaddyBindReader struct{}

func (failedCaddyBindReader) Read([]byte) (int, error) { return 0, io.ErrUnexpectedEOF }

type failedCaddyBindWriter struct{}

func (failedCaddyBindWriter) Write([]byte) (int, error) { return 0, io.ErrClosedPipe }
