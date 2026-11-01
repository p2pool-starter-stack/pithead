package cli

import (
	"bytes"
	"errors"
	"io"
	"strings"
	"testing"
)

func TestConfigEnvDashboardProtocol(t *testing.T) {
	table := `{"values":{"xvb":{"enabled":false},"dashboard":{"tari_required":false}},"appliance":{},"materialize":[],"LEGACY_ABSENT":[{"path":"xvb.enabled","value":true},{"path":"dashboard.tari_required","value":true}]}`
	frame := "diy\x00local\x004123456789\x00" + table + "\x00{}\x000\x00"
	for _, fixture := range []struct {
		name string
		args []string
		raw  string
		code int
	}{
		{"valid", nil, frame, 0},
		{"argument", []string{"extra"}, frame, 125},
		{"empty", nil, "", 125},
		{"missing-terminator", nil, strings.TrimSuffix(frame, "\x00"), 125},
		{"extra-field", nil, frame + "extra\x00", 125},
		{"missing-field", nil, strings.TrimPrefix(frame, "diy\x00"), 125},
		{"failed-producer", nil, strings.TrimSuffix(frame, "0\x00") + "23\x00", 125},
		{"bad-status", nil, strings.TrimSuffix(frame, "0\x00") + "00\x00", 125},
		{"bad-table", nil, strings.Replace(frame, table, "{}", 1), 125},
		{"invalid-config", nil, strings.Replace(frame, "\x00{}\x00", "\x00{\x00", 1), 125},
		{"duplicate-config", nil, strings.Replace(frame, "\x00{}\x00", "\x00{\"xvb\":{},\"xvb\":{}}\x00", 1), 125},
		{"unsupported-number", nil, strings.Replace(frame, "\x00{}\x00", "\x00{\"workers\":{\"api_port\":8080.0}}\x00", 1), 125},
	} {
		t.Run(fixture.name, func(t *testing.T) {
			var output bytes.Buffer
			err := configEnvDashboard(fixture.args, strings.NewReader(fixture.raw), &output)
			if fixture.code != 0 {
				var status *ExitError
				if !errors.As(err, &status) || status.Code != fixture.code || output.Len() != 0 {
					t.Fatalf("got %v and %q", err, output.Bytes())
				}
				return
			}
			fields := bytes.Split(output.Bytes(), []byte{0})
			if err != nil || len(fields) != 53 || len(fields[52]) != 0 {
				t.Fatalf("got %v and %q", err, output.Bytes())
			}
			if string(fields[0]) != "true" || string(fields[3]) != "41234567" || string(fields[5]) != "true" || string(fields[13]) != "{}" || string(fields[51]) != "true" {
				t.Fatalf("unexpected plan: %q", fields)
			}
		})
	}
}

func TestConfigEnvDashboardIOFailure(t *testing.T) {
	err := configEnvDashboard(nil, failedDashboardReader{}, io.Discard)
	var status *ExitError
	if !errors.As(err, &status) || status.Code != 125 {
		t.Fatalf("got %v", err)
	}
	table := `{"values":{"xvb":{"enabled":false},"dashboard":{"tari_required":false}},"appliance":{},"materialize":[],"LEGACY_ABSENT":[]}`
	frame := "diy\x00local\x004123456789\x00" + table + "\x00{}\x000\x00"
	err = configEnvDashboard(nil, strings.NewReader(frame), failedDashboardWriter{})
	if !errors.As(err, &status) || status.Code != 125 {
		t.Fatalf("got %v", err)
	}
}

type failedDashboardReader struct{}

func (failedDashboardReader) Read([]byte) (int, error) { return 0, io.ErrUnexpectedEOF }

type failedDashboardWriter struct{}

func (failedDashboardWriter) Write([]byte) (int, error) { return 0, io.ErrClosedPipe }
