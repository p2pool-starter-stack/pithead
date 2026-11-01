package cli

import (
	"bytes"
	"errors"
	"io"
	"os"
	"path/filepath"
	"testing"
)

func TestConfigStratumFrames(t *testing.T) {
	for _, fixture := range []struct {
		name, raw, frame string
	}{
		{"defaults", `{}`, "ok\x000.0.0.0\x003333\x00\x00"},
		{"raw-values", `{"p2pool":{"stratum_bind":"127.000.0.001","stratum_port":"00008"}}`, "ok\x00127.000.0.001\x0000008\x00\x00"},
		{"bad-bind", `{"p2pool":{"stratum_bind":"bad","stratum_port":{}}}`, "bind-error\x00bad\x00\x00p2pool.stratum_bind must be an IPv4 address like \"0.0.0.0\", \"127.0.0.1\", or your LAN IP (got \"bad\").\x00"},
		{"bad-port", `{"p2pool":{"stratum_port":0}}`, "port-error\x000.0.0.0\x000\x00p2pool.stratum_port must be an integer between 1 and 65535 (got \"0\").\x00"},
	} {
		t.Run(fixture.name, func(t *testing.T) {
			path := filepath.Join(t.TempDir(), "config.json")
			if err := os.WriteFile(path, []byte(fixture.raw), 0600); err != nil {
				t.Fatal(err)
			}
			var output bytes.Buffer
			if err := configStratum([]string{path}, &output); err != nil {
				t.Fatal(err)
			}
			if output.String() != fixture.frame {
				t.Fatalf("got %q; want %q", output.String(), fixture.frame)
			}
		})
	}
}

func TestConfigStratumUnsupported(t *testing.T) {
	path := filepath.Join(t.TempDir(), "config.json")
	for _, raw := range []string{`{`, `{"p2pool":[]}`, `{"p2pool":{"stratum_bind":{},"stratum_port":3333}}`, `{"p2pool":{"stratum_port":"33\n33"}}`} {
		if err := os.WriteFile(path, []byte(raw), 0600); err != nil {
			t.Fatal(err)
		}
		var output bytes.Buffer
		err := configStratum([]string{path}, &output)
		assertStratumUnsupported(t, err, output.String())
	}
	for _, args := range [][]string{nil, {"-"}, {path, "extra"}, {path + ".missing"}} {
		var output bytes.Buffer
		err := configStratum(args, &output)
		assertStratumUnsupported(t, err, output.String())
	}
}

func TestConfigStratumWriteFailure(t *testing.T) {
	path := filepath.Join(t.TempDir(), "config.json")
	if err := os.WriteFile(path, []byte(`{}`), 0600); err != nil {
		t.Fatal(err)
	}
	err := configStratum([]string{path}, failedStratumWriter{})
	assertStratumUnsupported(t, err, "")
}

func assertStratumUnsupported(t *testing.T, err error, output string) {
	t.Helper()
	var status *ExitError
	if !errors.As(err, &status) || status.Code != 125 || output != "" {
		t.Fatalf("got %v and %q", err, output)
	}
}

type failedStratumWriter struct{}

func (failedStratumWriter) Write([]byte) (int, error) { return 0, io.ErrClosedPipe }
