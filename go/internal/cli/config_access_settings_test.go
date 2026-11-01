package cli

import (
	"bytes"
	"io"
	"strings"
	"testing"
)

func TestConfigAccessSettingsSSHProtocol(t *testing.T) {
	tests := []struct {
		name, frame, want string
	}{
		{"disabled", "{}\x00false\x000\x000\x000\x00", "\x00"},
		{"valid", `{"ssh":{"enabled":true,"authorized_key":"ssh-ed25519 key"}}` + "\x00false\x000\x000\x000\x00", "\x00"},
		{"release", `{"ssh":null}` + "\x00true\x001\x000\x000\x00", "ssh.enabled is unavailable on a release image; build a debug image for SSH.\x00"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			var output bytes.Buffer
			if err := configAccessSettings([]string{"ssh"}, strings.NewReader(test.frame), &output); err != nil {
				t.Fatal(err)
			}
			if output.String() != test.want {
				t.Fatalf("got %q; want %q", output.String(), test.want)
			}
		})
	}
}

func TestConfigAccessSettingsNodeProtocol(t *testing.T) {
	frame := `{"monero":{"node_password":"secret"}}` + "\x00local\x00alice\x000\x00"
	var output bytes.Buffer
	if err := configAccessSettings([]string{"node"}, strings.NewReader(frame), &output); err != nil {
		t.Fatal(err)
	}
	if output.String() != "alice\x00secret\x00false\x00false\x00" {
		t.Fatalf("got %q", output.String())
	}
}

func TestConfigAccessSettingsRefusals(t *testing.T) {
	ssh := "{}\x00false\x000\x000\x000\x00"
	node := "{}\x00local\x00\x000\x00"
	for _, test := range []struct {
		name  string
		args  []string
		frame string
	}{
		{"no args", nil, ssh}, {"bad operation", []string{"other"}, ssh}, {"extra arg", []string{"ssh", "extra"}, ssh},
		{"ssh truncated", []string{"ssh"}, strings.TrimSuffix(ssh, "\x00")}, {"ssh trailing", []string{"ssh"}, ssh + "extra"},
		{"ssh bad bool", []string{"ssh"}, strings.Replace(ssh, "false", "0", 1)}, {"ssh producer", []string{"ssh"}, strings.TrimSuffix(ssh, "0\x00") + "1\x00"},
		{"node truncated", []string{"node"}, strings.TrimSuffix(node, "\x00")}, {"node trailing", []string{"node"}, node + "extra"},
		{"node producer", []string{"node"}, strings.TrimSuffix(node, "0\x00") + "1\x00"},
	} {
		t.Run(test.name, func(t *testing.T) {
			var output bytes.Buffer
			assertNetworkSettingsUnsupported(t, configAccessSettings(test.args, strings.NewReader(test.frame), &output), output.String())
		})
	}
	assertNetworkSettingsUnsupported(t, configAccessSettings([]string{"ssh"}, failedDashboardReader{}, io.Discard), "")
	assertNetworkSettingsUnsupported(t, configAccessSettings([]string{"node"}, strings.NewReader(node), failedDashboardWriter{}), "")
}
