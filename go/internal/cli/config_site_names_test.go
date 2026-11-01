package cli

import (
	"bytes"
	"io"
	"strings"
	"testing"
)

func TestConfigSiteNamesExpand(t *testing.T) {
	frame := "box.local\x00 172.17.0.1 \x00192.168.50\x00false\x004\x00box.local\x00172.17.0.1\x00192.168.50.2\x00localhost\x000\x00"
	var output bytes.Buffer
	if err := configSiteNames([]string{"expand"}, strings.NewReader(frame), &output); err != nil {
		t.Fatal(err)
	}
	if got, want := output.String(), "box.local 192.168.50.2 localhost\x00"; got != want {
		t.Fatalf("got %q; want %q", got, want)
	}
}

func TestConfigSiteNamesSAN(t *testing.T) {
	frame := "3\x00box.local\x00192.168.1.2\x002001:db8::1\x000\x00"
	var output bytes.Buffer
	if err := configSiteNames([]string{"san"}, strings.NewReader(frame), &output); err != nil {
		t.Fatal(err)
	}
	if got, want := output.String(), "DNS:box.local,IP:192.168.1.2,IP:2001:db8::1\x00"; got != want {
		t.Fatalf("got %q; want %q", got, want)
	}
}

func TestConfigSiteNamesRefusals(t *testing.T) {
	validExpand := "box\x00 \x00\x00false\x000\x000\x00"
	validSAN := "0\x000\x00"
	frames := []struct {
		args  []string
		frame string
	}{
		{nil, validExpand}, {[]string{"other"}, validExpand}, {[]string{"expand", "extra"}, validExpand},
		{[]string{"expand"}, ""}, {[]string{"expand"}, strings.TrimSuffix(validExpand, "\x00")},
		{[]string{"expand"}, validExpand + "extra"}, {[]string{"expand"}, strings.Replace(validExpand, "0\x000\x00", "00\x000\x00", 1)},
		{[]string{"expand"}, strings.TrimSuffix(validExpand, "0\x00") + "1\x00"},
		{[]string{"expand"}, "box\x00 \x00\x00false\x001\x00" + "10000000000002000::1" + "\x000\x00"},
		{[]string{"san"}, ""}, {[]string{"san"}, strings.TrimSuffix(validSAN, "\x00")},
		{[]string{"san"}, validSAN + "extra"}, {[]string{"san"}, "00\x000\x00"},
		{[]string{"san"}, strings.TrimSuffix(validSAN, "0\x00") + "1\x00"},
	}
	for _, test := range frames {
		var output bytes.Buffer
		assertNetworkSettingsUnsupported(t, configSiteNames(test.args, strings.NewReader(test.frame), &output), output.String())
	}
	var output bytes.Buffer
	assertNetworkSettingsUnsupported(t, configSiteNames([]string{"san"}, failedDashboardReader{}, &output), output.String())
	assertNetworkSettingsUnsupported(t, configSiteNames([]string{"san"}, strings.NewReader(validSAN), failedDashboardWriter{}), "")
	assertNetworkSettingsUnsupported(t, configSiteNames([]string{"san"}, io.LimitReader(strings.NewReader(validSAN), int64(len(validSAN))), failedDashboardWriter{}), "")
}
