package cli

import (
	"bytes"
	"errors"
	"io"
	"strings"
	"testing"
)

func TestKeepRunningScopeProtocol(t *testing.T) {
	input := "tor monerod\x004\x00--remove-orphans\x00--pull\x00missing\x00p2pool\x003\x00tor\x00p2pool\x00monerod\x000\x00"
	var output bytes.Buffer
	if err := keepRunningScope(nil, strings.NewReader(input), &output); err != nil {
		t.Fatal(err)
	}
	if got, want := output.String(), "3\x00--pull\x00--no-deps\x00p2pool\x00"; got != want {
		t.Fatalf("got %q, want %q", got, want)
	}
}

func TestKeepRunningScopeRawBytes(t *testing.T) {
	input := "keep \xffname\x001\x00\xfeoption\x002\x00\xffname\x00\xfdservice\x000\x00"
	var output bytes.Buffer
	if err := keepRunningScope(nil, strings.NewReader(input), &output); err != nil {
		t.Fatal(err)
	}
	if got, want := output.String(), "2\x00--no-deps\x00\xfdservice\x00"; got != want {
		t.Fatalf("got %q, want %q", got, want)
	}
}

func TestKeepRunningScopeRejectsMalformedInput(t *testing.T) {
	valid := "tor\x000\x001\x00p2pool\x000\x00"
	tests := []struct {
		name  string
		args  []string
		input string
	}{
		{"arguments", []string{"extra"}, valid},
		{"empty", nil, ""},
		{"missing terminator", nil, strings.TrimSuffix(valid, "\x00")},
		{"noncanonical arg count", nil, strings.Replace(valid, "\x000\x00", "\x0000\x00", 1)},
		{"too many args", nil, "tor\x008193\x000\x000\x00"},
		{"negative service count", nil, "tor\x000\x00-1\x000\x00"},
		{"too many services", nil, "tor\x000\x008193\x000\x00"},
		{"wrong arg count", nil, "tor\x001\x001\x00p2pool\x000\x00"},
		{"wrong service count", nil, "tor\x000\x002\x00p2pool\x000\x00"},
		{"producer failed", nil, strings.TrimSuffix(valid, "0\x00") + "1\x00"},
		{"producer status", nil, strings.TrimSuffix(valid, "0\x00") + "00\x00"},
		{"trailing", nil, valid + "extra\x00"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			var output bytes.Buffer
			err := keepRunningScope(test.args, strings.NewReader(test.input), &output)
			assertKeepRunningUnsupported(t, err, output.String())
		})
	}
}

func TestKeepRunningScopeMaximumResultCount(t *testing.T) {
	var input bytes.Buffer
	input.WriteString("keep\x008191\x00")
	for range 8191 {
		input.WriteString("-x\x00")
	}
	input.WriteString("1\x00service\x000\x00")
	var output bytes.Buffer
	if err := keepRunningScope(nil, &input, &output); err != nil {
		t.Fatal(err)
	}
	if !bytes.HasPrefix(output.Bytes(), []byte("8193\x00-x\x00")) {
		t.Fatalf("unexpected output prefix %q", output.Bytes()[:16])
	}
}

func TestKeepRunningScopeBoundsAndIO(t *testing.T) {
	var output bytes.Buffer
	err := keepRunningScope(nil, strings.NewReader(strings.Repeat("x", keepRunningMaxInput+1)), &output)
	assertKeepRunningUnsupported(t, err, output.String())
	err = keepRunningScope(nil, keepRunningFailedReader{}, &output)
	assertKeepRunningUnsupported(t, err, output.String())
	valid := "tor\x000\x001\x00p2pool\x000\x00"
	for _, writer := range []io.Writer{keepRunningFailedWriter{}, keepRunningShortWriter{}} {
		err = keepRunningScope(nil, strings.NewReader(valid), writer)
		assertKeepRunningUnsupported(t, err, "")
	}
}

func assertKeepRunningUnsupported(t *testing.T, err error, output string) {
	t.Helper()
	var status *ExitError
	if !errors.As(err, &status) || status.Code != 125 || output != "" {
		t.Fatalf("got %v and %q", err, output)
	}
}

type keepRunningFailedReader struct{}

func (keepRunningFailedReader) Read([]byte) (int, error) { return 0, io.ErrUnexpectedEOF }

type keepRunningFailedWriter struct{}

func (keepRunningFailedWriter) Write([]byte) (int, error) { return 0, io.ErrClosedPipe }

type keepRunningShortWriter struct{}

func (keepRunningShortWriter) Write(value []byte) (int, error) { return len(value) - 1, nil }
