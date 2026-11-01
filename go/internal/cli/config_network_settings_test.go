package cli

import (
	"bytes"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestConfigNetworkSettingsFrames(t *testing.T) {
	for _, fixture := range []struct {
		name, raw, mono, tari, count, first, last, reason string
	}{
		{"defaults", `{}`, "local", "off", "12", "172.28.0.0/24", "mini", ""},
		{"bad-subnet", `{"network":{"subnet":"bad"}}`, "local", "off", "1", "bad", "", "network.subnet must be an X.Y.Z.0/24 block"},
		{"bad-ipv4", `{"network":{"subnet":"999.1.2.0/24"}}`, "local", "off", "2", "999.1.2.0/24", "", "network.subnet is not a valid IPv4 /24"},
		{"missing-remote", `{}`, "remote", "off", "11", "172.28.0.0/24", "", "monero.mode is \"remote\" but monero.remote.host is not set in "},
		{"bad-pool", `{"p2pool":{"pool":"bad"}}`, "local", "off", "12", "172.28.0.0/24", "bad", "p2pool.pool must be"},
	} {
		t.Run(fixture.name, func(t *testing.T) {
			path := filepath.Join(t.TempDir(), "config.json")
			if err := os.WriteFile(path, []byte(fixture.raw), 0600); err != nil {
				t.Fatal(err)
			}
			var output bytes.Buffer
			if err := configNetworkSettings([]string{path, fixture.mono, fixture.tari}, &output); err != nil {
				t.Fatal(err)
			}
			fields := strings.Split(output.String(), "\x00")
			if len(fields) != 15 || fields[0] != fixture.count || fields[1] != fixture.first || fields[12] != fixture.last || fields[14] != "" {
				t.Fatalf("got frame %q", fields)
			}
			if fixture.reason == "" && fields[13] != "" || fixture.reason != "" && !strings.HasPrefix(fields[13], fixture.reason) {
				t.Fatalf("got reason %q; want prefix %q", fields[13], fixture.reason)
			}
			if fixture.name == "missing-remote" && !strings.HasSuffix(fields[13], path+".") {
				t.Fatalf("missing config path in %q", fields[13])
			}
		})
	}
}

func TestConfigNetworkSettingsUnsupported(t *testing.T) {
	path := filepath.Join(t.TempDir(), "config.json")
	for _, raw := range []string{`{`, `{"network":{"subnet":[]}}`, `{"network":{"subnet":"172.28.0.0/24\n"}}`} {
		if err := os.WriteFile(path, []byte(raw), 0600); err != nil {
			t.Fatal(err)
		}
		var output bytes.Buffer
		assertNetworkSettingsUnsupported(t, configNetworkSettings([]string{path, "local", "off"}, &output), output.String())
	}
	for _, args := range [][]string{nil, {path}, {"-", "local", "off"}, {path, "local", "off", "extra"}, {path + ".missing", "local", "off"}} {
		var output bytes.Buffer
		assertNetworkSettingsUnsupported(t, configNetworkSettings(args, &output), output.String())
	}
}

func TestConfigNetworkSettingsWriteFailure(t *testing.T) {
	path := filepath.Join(t.TempDir(), "config.json")
	if err := os.WriteFile(path, []byte(`{}`), 0600); err != nil {
		t.Fatal(err)
	}
	assertNetworkSettingsUnsupported(t, configNetworkSettings([]string{path, "local", "off"}, failedNetworkSettingsWriter{}), "")
}

func assertNetworkSettingsUnsupported(t *testing.T, err error, output string) {
	t.Helper()
	var status *ExitError
	if !errors.As(err, &status) || status.Code != 125 || output != "" {
		t.Fatalf("got %v and %q", err, output)
	}
}

type failedNetworkSettingsWriter struct{}

func (failedNetworkSettingsWriter) Write([]byte) (int, error) { return 0, io.ErrClosedPipe }
