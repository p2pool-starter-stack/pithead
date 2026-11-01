package cli

import (
	"bytes"
	"io"
	"strings"
	"testing"
)

func TestConfigDashboardAuthFrames(t *testing.T) {
	for _, fixture := range []struct {
		op, frame, expected string
	}{
		{"settings", "{}\x000\x00", "admin\x00\x00\x00"},
		{"settings", "{\"dashboard\":{\"auth\":{\"password\":\"long enough\"}}}\x000\x00", "admin\x00long enough\x00\x00"},
		{"policy", "{}\x00\x00pithead\x000\x00", "3\x00false\x00false\x00false\x00\x00"},
	} {
		var output bytes.Buffer
		if err := configDashboardAuth([]string{fixture.op}, strings.NewReader(fixture.frame), &output); err != nil || output.String() != fixture.expected {
			t.Fatalf("got %v and %q; want %q", err, output.String(), fixture.expected)
		}
	}
	for _, fixture := range []struct {
		op, frame, reason string
	}{
		{"settings", "{\"dashboard\":{\"auth\":{\"password\":\"short\"}}}\x000\x00", "dashboard.auth.password must be"},
		{"policy", "{\"dashboard\":{\"onion\":{\"enabled\":true}}}\x00\x00pithead\x000\x00", "dashboard.onion.enabled is true"},
		{"policy", "{\"dashboard\":{\"control\":{\"enabled\":true}}}\x00\x00pithead\x000\x00", "'pithead apply'"},
	} {
		var output bytes.Buffer
		if err := configDashboardAuth([]string{fixture.op}, strings.NewReader(fixture.frame), &output); err != nil || !strings.Contains(output.String(), fixture.reason) {
			t.Fatalf("got %v and %q", err, output.String())
		}
	}
}

func TestConfigDashboardAuthRefusals(t *testing.T) {
	for _, fixture := range []struct {
		args  []string
		frame string
	}{
		{nil, "{}\x000\x00"},
		{[]string{"unknown"}, "{}\x000\x00"},
		{[]string{"settings", "extra"}, "{}\x000\x00"},
		{[]string{"settings"}, "{}\x000"},
		{[]string{"settings"}, "{}\x009\x00"},
		{[]string{"settings"}, "{}\x0000\x00"},
		{[]string{"settings"}, "{}\x000\x00extra"},
		{[]string{"settings"}, "{\x000\x00"},
		{[]string{"settings"}, "{\"dashboard\":{\"auth\":{\"password\":[]}}}\x000\x00"},
		{[]string{"policy"}, "{}\x00\x000\x00"},
		{[]string{"policy"}, "{}\x00\x00pithead\x001\x00"},
		{[]string{"policy"}, "{}\x00\x00pithead\x000\x00extra\x00"},
	} {
		var output bytes.Buffer
		assertNetworkSettingsUnsupported(t, configDashboardAuth(fixture.args, strings.NewReader(fixture.frame), &output), output.String())
	}
	assertNetworkSettingsUnsupported(t, configDashboardAuth([]string{"settings"}, failedDashboardReader{}, io.Discard), "")
	assertNetworkSettingsUnsupported(t, configDashboardAuth([]string{"settings"}, strings.NewReader("{}\x000\x00"), failedDashboardWriter{}), "")
	assertNetworkSettingsUnsupported(t, configDashboardAuth([]string{"policy"}, strings.NewReader("{}\x00\x00pithead\x000\x00"), failedDashboardWriter{}), "")
}
