package cli

import (
	"bytes"
	"errors"
	"io"
	"strings"
	"testing"
)

const dashboardAccessTestTable = `{"values":{"dashboard":{"host":"auto"}},"appliance":{},"materialize":[],"LEGACY_ABSENT":[]}`

func TestConfigDashboardAccessFrames(t *testing.T) {
	for _, fixture := range []struct {
		raw, assigned, host, port, timezone, needs, reason string
	}{
		{`{}`, "5", "", "", "", "true", ""},
		{`{"dashboard":{"host":"box.lan","port":8443,"timezone":"UTC"}}`, "5", "box.lan", "8443", "UTC", "false", ""},
		{`{"dashboard":{"host":"bad host","port":[]}}`, "1", "bad host", "", "", "false", "dashboard.host must be"},
		{`{"dashboard":{"port":"080","secure":[]}}`, "2", "", "080", "", "false", "dashboard.port must be"},
	} {
		frame := "diy\x00" + dashboardAccessTestTable + "\x00" + fixture.raw + "\x000\x00"
		var output bytes.Buffer
		if err := configDashboardAccess(nil, strings.NewReader(frame), &output); err != nil {
			t.Fatal(err)
		}
		fields := strings.Split(output.String(), "\x00")
		if len(fields) != 9 || fields[0] != fixture.assigned || fields[1] != fixture.host || fields[2] != fixture.port || fields[5] != fixture.timezone || fields[6] != fixture.needs || fields[8] != "" || !strings.HasPrefix(fields[7], fixture.reason) {
			t.Fatalf("unexpected frame %q", fields)
		}
		if fixture.reason == "" && (fields[3] != "true" || fields[4] != "false" || fields[7] != "") {
			t.Fatalf("unexpected valid plan %q", fields)
		}
	}
}

func TestConfigDashboardAccessRefusals(t *testing.T) {
	valid := "diy\x00" + dashboardAccessTestTable + "\x00{}\x000\x00"
	for _, frame := range []string{
		"", strings.TrimSuffix(valid, "\x00"), valid + "extra", valid + "\x00",
		strings.TrimSuffix(valid, "0\x00") + "1\x00",
		strings.TrimSuffix(valid, "0\x00") + "00\x00",
		strings.Replace(valid, dashboardAccessTestTable, "{}", 1),
		strings.Replace(valid, "\x00{}\x00", "\x00{\x00", 1),
		strings.Replace(valid, "\x00{}\x00", "\x00{\"dashboard\":{\"host\":[]}}\x00", 1),
	} {
		var output bytes.Buffer
		assertNetworkSettingsUnsupported(t, configDashboardAccess(nil, strings.NewReader(frame), &output), output.String())
	}
	var output bytes.Buffer
	assertNetworkSettingsUnsupported(t, configDashboardAccess([]string{"extra"}, strings.NewReader(valid), &output), output.String())
	assertNetworkSettingsUnsupported(t, configDashboardAccess(nil, failedDashboardReader{}, io.Discard), "")
	err := configDashboardAccess(nil, strings.NewReader(valid), failedDashboardWriter{})
	var status *ExitError
	if !errors.As(err, &status) || status.Code != 125 {
		t.Fatalf("got %v", err)
	}
}
