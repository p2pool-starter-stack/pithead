package cli

import (
	"bytes"
	"errors"
	"io"
	"strings"
	"testing"
)

func TestConfigInputValidationProtocol(t *testing.T) {
	tests := []struct {
		name   string
		args   []string
		input  string
		output string
		code   int
	}{
		{"ok", nil, `{}` + "\x000\x00", "ok\x00\x00", 0},
		{"document", nil, `{` + "\x000\x00", "document\x00not valid JSON\x00", 0},
		{"webhooks", nil, `{"notifications":{"webhooks":false}}` + "\x000\x00", "webhooks\x00notifications.webhooks must be an array of URL strings.\x00", 0},
		{"controls", nil, `{"value":"bad\n"}` + "\x000\x00", "controls\x00control-character\x00", 0},
		{"arguments", []string{"extra"}, `{}` + "\x000\x00", "", 125},
		{"empty", nil, "", "", 125},
		{"unterminated", nil, `{}` + "\x000", "", 125},
		{"extra", nil, `{}` + "\x000\x00extra\x00", "", 125},
		{"producer failed", nil, `{}` + "\x001\x00", "", 125},
		{"producer status", nil, `{}` + "\x0000\x00", "", 125},
		{"raw nul", nil, "{\x00}\x000\x00", "", 125},
		{"unsupported", nil, `"\ud800"` + "\x000\x00", "", 125},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			var output bytes.Buffer
			err := configInputValidation(test.args, strings.NewReader(test.input), &output)
			if test.code == 0 {
				if err != nil || output.String() != test.output {
					t.Fatalf("got %v and %q", err, output.String())
				}
				return
			}
			var status *ExitError
			if !errors.As(err, &status) || status.Code != test.code || output.Len() != 0 {
				t.Fatalf("got %v and %q", err, output.String())
			}
		})
	}
}

func TestConfigInputValidationIOFailure(t *testing.T) {
	var status *ExitError
	err := configInputValidation(nil, inputValidationFailedReader{}, io.Discard)
	if !errors.As(err, &status) || status.Code != 125 {
		t.Fatalf("read failure = %v", err)
	}
	for _, output := range []io.Writer{inputValidationFailedWriter{}, inputValidationShortWriter{}} {
		err = configInputValidation(nil, strings.NewReader("{}\x000\x00"), output)
		if !errors.As(err, &status) || status.Code != 125 {
			t.Fatalf("write failure = %v", err)
		}
	}
}

type inputValidationFailedReader struct{}

func (inputValidationFailedReader) Read([]byte) (int, error) { return 0, io.ErrUnexpectedEOF }

type inputValidationFailedWriter struct{}

func (inputValidationFailedWriter) Write([]byte) (int, error) { return 0, io.ErrClosedPipe }

type inputValidationShortWriter struct{}

func (inputValidationShortWriter) Write(value []byte) (int, error) { return len(value) - 1, nil }
