package cli

import (
	"bytes"
	"errors"
	"io"
	"strings"
	"testing"
)

func TestLifecycleOptionsProtocol(t *testing.T) {
	tests := []struct {
		name   string
		args   []string
		input  string
		output string
		code   int
	}{
		{"render", nil, "render\x000\x000\x00", "ok\x00\x000\x000\x000\x00", 0},
		{"apply", nil, "apply\x003\x00-y\x00--dry-run\x00--porcelain\x000\x00", "ok\x00\x001\x001\x001\x00", 0},
		{"apply unknown", nil, "apply\x002\x00-y\x00bad\x000\x00", "unknown\x00bad\x001\x000\x000\x00", 0},
		{"restart extra", nil, "restart\x002\x00tor\x00ignored\x000\x00", "ok\x00\x000\x000\x000\x00", 0},
		{"arguments", []string{"extra"}, "render\x000\x000\x00", "", 125},
		{"unsupported", nil, "upgrade\x000\x000\x00", "", 125},
		{"empty", nil, "", "", 125},
		{"missing footer", nil, "render\x000\x00", "", 125},
		{"bad count", nil, "render\x0000\x000\x00", "", 125},
		{"negative count", nil, "render\x00-1\x000\x00", "", 125},
		{"wrong count", nil, "render\x001\x000\x00", "", 125},
		{"producer failed", nil, "render\x000\x001\x00", "", 125},
		{"trailing", nil, "render\x000\x000\x00extra\x00", "", 125},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			var output bytes.Buffer
			err := lifecycleOptions(test.args, strings.NewReader(test.input), &output)
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

func TestLifecycleOptionsIOFailure(t *testing.T) {
	var status *ExitError
	err := lifecycleOptions(nil, lifecycleOptionsFailedReader{}, io.Discard)
	if !errors.As(err, &status) || status.Code != 125 {
		t.Fatalf("read failure = %v", err)
	}
	for _, output := range []io.Writer{lifecycleOptionsFailedWriter{}, lifecycleOptionsShortWriter{}} {
		err = lifecycleOptions(nil, strings.NewReader("render\x000\x000\x00"), output)
		if !errors.As(err, &status) || status.Code != 125 {
			t.Fatalf("write failure = %v", err)
		}
	}
}

type lifecycleOptionsFailedReader struct{}

func (lifecycleOptionsFailedReader) Read([]byte) (int, error) { return 0, io.ErrUnexpectedEOF }

type lifecycleOptionsFailedWriter struct{}

func (lifecycleOptionsFailedWriter) Write([]byte) (int, error) { return 0, io.ErrClosedPipe }

type lifecycleOptionsShortWriter struct{}

func (lifecycleOptionsShortWriter) Write(value []byte) (int, error) { return len(value) - 1, nil }
