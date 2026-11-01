package cli

import (
	"bytes"
	"io"
	"strings"
	"testing"
)

func TestConfigDirectoriesProtocol(t *testing.T) {
	for _, fixture := range []struct {
		raw, monero, dashboard, flag, root string
	}{
		{`{}`, "/install/data/monero", "/install/data/dashboard", "1", "/install/data"},
		{`{"dashboard":{"data_dir":"/custom/panel"}}`, "/install/data/monero", "/custom/panel", "0", "/install/data"},
		{`{"monero":{"data_dir":"/shared/monero"},"tari":{"data_dir":"/shared/tari"},"p2pool":{"data_dir":"/shared/pool"},"tor":{"data_dir":"/shared/tor"}}`, "/shared/monero", "/shared/dashboard", "1", "/shared"},
	} {
		var output bytes.Buffer
		frame := "/install\x00" + fixture.raw + "\x000\x00"
		if err := configDirectories(nil, strings.NewReader(frame), &output); err != nil {
			t.Fatal(err)
		}
		fields := strings.Split(output.String(), "\x00")
		if len(fields) != 13 || fields[0] != fixture.monero || fields[4] != fixture.dashboard || fields[5] != fixture.flag || fields[10] != fixture.root || fields[12] != "" {
			t.Fatalf("unexpected plan %q", fields)
		}
	}
}

func TestConfigDirectoriesRefusals(t *testing.T) {
	valid := "/install\x00{}\x000\x00"
	for _, frame := range []string{
		"", strings.TrimSuffix(valid, "\x00"), valid + "extra", valid + "\x00",
		strings.TrimSuffix(valid, "0\x00") + "9\x00",
		strings.TrimSuffix(valid, "0\x00") + "00\x00",
		strings.Replace(valid, "/install", "relative", 1),
		strings.Replace(valid, "{}", "{", 1),
		strings.Replace(valid, "{}", `{"monero":{"data_dir":[]}}`, 1),
		strings.Replace(valid, "{}", `{"monero":{"data_dir":"relative"}}`, 1),
	} {
		var output bytes.Buffer
		assertNetworkSettingsUnsupported(t, configDirectories(nil, strings.NewReader(frame), &output), output.String())
	}
	var output bytes.Buffer
	assertNetworkSettingsUnsupported(t, configDirectories([]string{"extra"}, strings.NewReader(valid), &output), output.String())
	assertNetworkSettingsUnsupported(t, configDirectories(nil, failedDashboardReader{}, io.Discard), "")
	assertNetworkSettingsUnsupported(t, configDirectories(nil, strings.NewReader(valid), failedDashboardWriter{}), "")
}
