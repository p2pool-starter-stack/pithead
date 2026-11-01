package cli

import (
	"bytes"
	"io"
	"strings"
	"testing"
)

func TestConfigComposeProjectProtocol(t *testing.T) {
	for _, test := range []struct{ frame, want string }{
		{"\x000\x00\x00missing\x000\x00", "pithead\x00\x000\x00"},
		{"COMPOSE_PROJECT_NAME=pithead-gate\n\x000\x00\x00file\x000\x00", "pithead-gate\x00\x000\x00"},
		{"\x001\x00chosen\x00missing\x000\x00", "chosen\x00\x000\x00"},
		{"COMPOSE_PROJECT_NAME=bad/name\n\x000\x00\x00file\x000\x00", "\x00COMPOSE_PROJECT_NAME must be a literal lowercase Compose project name.\x001\x00"},
	} {
		var output bytes.Buffer
		if err := configComposeProject(nil, strings.NewReader(test.frame), &output); err != nil {
			t.Fatalf("configComposeProject(%q) error: %v", test.frame, err)
		}
		if output.String() != test.want {
			t.Fatalf("configComposeProject(%q) = %q; want %q", test.frame, output.String(), test.want)
		}
	}
}

func TestConfigComposeProjectRefusals(t *testing.T) {
	valid := "\x000\x00\x00missing\x000\x00"
	for _, frame := range []string{
		"", strings.TrimSuffix(valid, "\x00"), valid + "extra", valid + "\x00",
		strings.TrimSuffix(valid, "0\x00") + "1\x00",
		strings.Replace(valid, "\x000\x00", "\x002\x00", 1),
		strings.Replace(valid, "missing", "unknown", 1),
		"\x000\x00ignored\x00missing\x000\x00",
		"raw\x000\x00\x00missing\x000\x00",
		"raw\x001\x00override\x00file\x000\x00",
	} {
		var output bytes.Buffer
		assertNetworkSettingsUnsupported(t, configComposeProject(nil, strings.NewReader(frame), &output), output.String())
	}
	for _, args := range [][]string{{"extra"}, {"one", "two"}} {
		var output bytes.Buffer
		assertNetworkSettingsUnsupported(t, configComposeProject(args, strings.NewReader(valid), &output), output.String())
	}
	assertNetworkSettingsUnsupported(t, configComposeProject(nil, failedDashboardReader{}, io.Discard), "")
	assertNetworkSettingsUnsupported(t, configComposeProject(nil, strings.NewReader(valid), failedDashboardWriter{}), "")
}
