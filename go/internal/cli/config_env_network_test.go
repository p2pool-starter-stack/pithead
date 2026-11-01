package cli

import (
	"bytes"
	"errors"
	"io"
	"strings"
	"testing"
)

func TestConfigEnvNetworkProtocol(t *testing.T) {
	frame := "local\x00off\x00172.28.0\x00\x00\x00\x00\x00\x00false\x00false\x00{}\x000\x00"
	for _, fixture := range []struct {
		name string
		args []string
		raw  string
		code int
	}{
		{"valid", nil, frame, 0},
		{"arguments", []string{"extra"}, frame, 125},
		{"empty", nil, "", 125},
		{"missing-terminator", nil, strings.TrimSuffix(frame, "\x00"), 125},
		{"missing-field", nil, strings.TrimPrefix(frame, "local\x00"), 125},
		{"extra-field", nil, frame + "extra\x00", 125},
		{"producer-failed", nil, strings.TrimSuffix(frame, "0\x00") + "1\x00", 125},
		{"producer-status-invalid", nil, strings.TrimSuffix(frame, "0\x00") + "00\x00", 125},
		{"invalid-config", nil, strings.Replace(frame, "{}", "{", 1), 125},
		{"unsupported-config", nil, strings.Replace(frame, "{}", `{"monero":{"out_peers":48.0}}`, 1), 125},
	} {
		t.Run(fixture.name, func(t *testing.T) {
			var output bytes.Buffer
			err := configEnvNetwork(fixture.args, strings.NewReader(fixture.raw), &output)
			if fixture.code != 0 {
				var status *ExitError
				if !errors.As(err, &status) || status.Code != fixture.code || output.Len() != 0 {
					t.Fatalf("got %v and %q", err, output.Bytes())
				}
				return
			}
			fields := bytes.Split(output.Bytes(), []byte{0})
			if err != nil || len(fields) != 20 || len(fields[19]) != 0 {
				t.Fatalf("got %v and %q", err, output.Bytes())
			}
			if string(fields[0]) != "172.28.0.26" || string(fields[4]) != "local_node" || string(fields[18]) != "--socks5 172.28.0.25:9050 --socks5-proxy-type tor --no-dns" {
				t.Fatalf("unexpected plan: %q", fields)
			}
		})
	}
}

func TestConfigEnvNetworkIOFailure(t *testing.T) {
	err := configEnvNetwork(nil, failedNetworkReader{}, io.Discard)
	var status *ExitError
	if !errors.As(err, &status) || status.Code != 125 {
		t.Fatalf("got %v", err)
	}
	frame := "local\x00off\x00172.28.0\x00\x00\x00\x00\x00\x00false\x00false\x00{}\x000\x00"
	err = configEnvNetwork(nil, strings.NewReader(frame), failedNetworkWriter{})
	if !errors.As(err, &status) || status.Code != 125 {
		t.Fatalf("got %v", err)
	}
}

type failedNetworkReader struct{}

func (failedNetworkReader) Read([]byte) (int, error) { return 0, io.ErrUnexpectedEOF }

type failedNetworkWriter struct{}

func (failedNetworkWriter) Write([]byte) (int, error) { return 0, io.ErrClosedPipe }
