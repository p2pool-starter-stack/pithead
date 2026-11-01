package config

import (
	"errors"
	"testing"
)

func TestParseSSHSettings(t *testing.T) {
	tests := []struct {
		name, raw string
		input     SSHSettingsInput
		want      string
	}{
		{name: "absent", raw: `{}`},
		{name: "disabled", raw: `{"ssh":{"enabled":false,"authorized_key":[]}}`},
		{name: "key", raw: `{"ssh":{"enabled":true,"authorized_key":"ssh-ed25519 key"}}`},
		{name: "ecdsa", raw: `{"ssh":{"enabled":true,"authorized_key":"ecdsa-sha2 key\n\n"}}`},
		{name: "invalid key", raw: `{"ssh":{"enabled":true,"authorized_key":"rsa key"}}`, want: "ssh.enabled is true but ssh.authorized_key is not a public key (expected it to start with ssh-, ecdsa- or sk-). Paste the PUBLIC key (e.g. ~/.ssh/id_ed25519.pub)."},
		{name: "release absent", raw: `{}`, input: SSHSettingsInput{Release: true, ConfigSet: "1"}},
		{name: "release carried", raw: `{"ssh":{"enabled":true}}`, input: SSHSettingsInput{Release: true, ConfigSet: "1", Carried: "1"}},
		{name: "release staged", raw: `{"ssh":null}`, input: SSHSettingsInput{Release: true, ConfigSet: "1"}, want: "ssh.enabled is unavailable on a release image; build a debug image for SSH."},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			got, err := ParseSSHSettings([]byte(test.raw), test.input)
			if err != nil || got != test.want {
				t.Fatalf("ParseSSHSettings() = %q, %v; want %q, nil", got, err, test.want)
			}
		})
	}
}

func TestParseSSHSettingsRejectsUnsupportedInput(t *testing.T) {
	for _, raw := range []string{`[]`, `{"ssh":{"enabled":true,"authorized_key":[]}}`, `{"ssh":{"enabled":true,"authorized_key":1.5}}`, `{"ssh":1}`} {
		got, err := ParseSSHSettings([]byte(raw), SSHSettingsInput{})
		if got != "" || !errors.Is(err, ErrUnsupportedValidation) {
			t.Fatalf("ParseSSHSettings(%q) = %q, %v", raw, got, err)
		}
	}
}
