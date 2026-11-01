package cli

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestConfigProxySettingsFrames(t *testing.T) {
	for _, fixture := range []struct {
		raw, assigned, password, tls, donation, reason string
	}{
		{`{}`, "3", "", "false", "0", ""},
		{`{"p2pool":{"stratum_password":"hello:rig@-._","stratum_tls":"ON"},"proxy":{"donate_level":"09"}}`, "3", "hello:rig@-._", "true", "09", ""},
		{`{"p2pool":{"stratum_password":"bad space"}}`, "1", "bad space", "", "", "p2pool.stratum_password must be"},
		{`{"proxy":{"donate_level":100}}`, "3", "", "false", "100", "proxy.donate_level must be"},
	} {
		path := filepath.Join(t.TempDir(), "config.json")
		if err := os.WriteFile(path, []byte(fixture.raw), 0600); err != nil {
			t.Fatal(err)
		}
		var output bytes.Buffer
		if err := configProxySettings([]string{path}, &output); err != nil {
			t.Fatal(err)
		}
		fields := strings.Split(output.String(), "\x00")
		if len(fields) != 6 || fields[0] != fixture.assigned || fields[1] != fixture.password || fields[2] != fixture.tls || fields[3] != fixture.donation || fields[5] != "" || !strings.HasPrefix(fields[4], fixture.reason) {
			t.Fatalf("unexpected frame %q", fields)
		}
		if fixture.reason == "" && fields[4] != "" {
			t.Fatalf("unexpected reason %q", fields[4])
		}
	}
}

func TestConfigProxySettingsRefusal(t *testing.T) {
	path := filepath.Join(t.TempDir(), "config.json")
	for _, raw := range []string{`{`, `{"p2pool":{"stratum_password":"auto"}}`, `{"proxy":{"donate_level":{}}}`} {
		if err := os.WriteFile(path, []byte(raw), 0600); err != nil {
			t.Fatal(err)
		}
		var output bytes.Buffer
		assertNetworkSettingsUnsupported(t, configProxySettings([]string{path}, &output), output.String())
	}
	for _, args := range [][]string{nil, {"-"}, {path, "extra"}, {path + ".missing"}} {
		var output bytes.Buffer
		assertNetworkSettingsUnsupported(t, configProxySettings(args, &output), output.String())
	}
	if err := os.WriteFile(path, []byte(`{}`), 0600); err != nil {
		t.Fatal(err)
	}
	assertNetworkSettingsUnsupported(t, configProxySettings([]string{path}, failedNetworkSettingsWriter{}), "")
}
