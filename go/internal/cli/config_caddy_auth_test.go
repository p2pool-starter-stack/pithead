package cli

import (
	"bytes"
	"encoding/base64"
	"errors"
	"io"
	"strings"
	"testing"
)

func TestConfigCaddyAuthProtocol(t *testing.T) {
	encoded := base64.StdEncoding.EncodeToString([]byte("hash\n\n"))
	for _, fixture := range []struct {
		name string
		args []string
		raw  string
		want string
		code int
	}{
		{"auth", []string{"auth"}, "operator\x00" + encoded + "\x000\x00", "    basic_auth {\n        operator hash\n    }\x00", 0},
		{"disabled", []string{"auth"}, "operator\x00\x000\x00", "\x00", 0},
		{"boot", []string{"boot"}, "YWJj\x000\x00", "08b3f0effcecf6797c13b64aeb65c40b624e28f22e25cc4a81b647f32ed13f8d\x00", 0},
		{"no-operation", nil, "", "", 125},
		{"extra-argument", []string{"auth", "extra"}, "operator\x00\x000\x00", "", 125},
		{"unknown-operation", []string{"other"}, "\x000\x00", "", 125},
		{"empty", []string{"auth"}, "", "", 125},
		{"missing-terminator", []string{"auth"}, "operator\x00\x000", "", 125},
		{"failed-auth-producer", []string{"auth"}, "operator\x00\x001\x00", "", 125},
		{"failed-boot-producer", []string{"boot"}, "\x001\x00", "", 125},
		{"bad-status", []string{"boot"}, "\x0000\x00", "", 125},
		{"extra-field", []string{"boot"}, "\x000\x00extra\x00", "", 125},
		{"malformed-base64", []string{"auth"}, "operator\x00%%%\x000\x00", "", 125},
		{"noncanonical-base64", []string{"auth"}, "operator\x00aGFz\naA==\x000\x00", "", 125},
	} {
		t.Run(fixture.name, func(t *testing.T) {
			var output bytes.Buffer
			err := configCaddyAuth(fixture.args, strings.NewReader(fixture.raw), &output)
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

func TestConfigCaddyAuthIOFailure(t *testing.T) {
	var status *ExitError
	err := configCaddyAuth([]string{"boot"}, failedCaddyAuthReader{}, io.Discard)
	if !errors.As(err, &status) || status.Code != 125 {
		t.Fatalf("got %v", err)
	}
	err = configCaddyAuth([]string{"boot"}, strings.NewReader("\x000\x00"), failedCaddyAuthWriter{})
	if !errors.As(err, &status) || status.Code != 125 {
		t.Fatalf("got %v", err)
	}
}

type failedCaddyAuthReader struct{}

func (failedCaddyAuthReader) Read([]byte) (int, error) { return 0, io.ErrUnexpectedEOF }

type failedCaddyAuthWriter struct{}

func (failedCaddyAuthWriter) Write([]byte) (int, error) { return 0, io.ErrClosedPipe }
