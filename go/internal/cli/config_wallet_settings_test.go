package cli

import (
	"bytes"
	"io"
	"strings"
	"testing"
)

func TestConfigWalletSettingsProtocol(t *testing.T) {
	tests := []struct {
		name, frame, want string
	}{
		{"values", `{"monero":{"wallet_address":"monero"},"tari":{"wallet_address":"tari"}}` + "\x00local\x00config.json\x000\x00", "2\x00monero\x00tari\x00\x00"},
		{"bad mode", "{\x00bad\x00config.json\x000\x00", "0\x00\x00\x00tari.mode must be \"local\", \"remote\" or \"off\" (got \"bad\").\x00"},
		{"missing", `{"tari":{"wallet_address":"tari"}}` + "\x00local\x00config.json\x000\x00", "2\x00\x00tari\x00Missing required wallet addresses in config.json.\x00"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			var output bytes.Buffer
			if err := configWalletSettings(nil, strings.NewReader(test.frame), &output); err != nil {
				t.Fatal(err)
			}
			if output.String() != test.want {
				t.Fatalf("got %q; want %q", output.String(), test.want)
			}
		})
	}
}

func TestConfigWalletSettingsRefusals(t *testing.T) {
	valid := "{}\x00off\x00config.json\x000\x00"
	for _, frame := range []string{
		"", strings.TrimSuffix(valid, "\x00"), valid + "extra", valid + "\x00",
		strings.TrimSuffix(valid, "0\x00") + "1\x00",
		strings.TrimSuffix(valid, "0\x00") + "00\x00",
		strings.Replace(valid, "{}", "{", 1),
	} {
		var output bytes.Buffer
		assertNetworkSettingsUnsupported(t, configWalletSettings(nil, strings.NewReader(frame), &output), output.String())
	}
	var output bytes.Buffer
	assertNetworkSettingsUnsupported(t, configWalletSettings([]string{"extra"}, strings.NewReader(valid), &output), output.String())
	assertNetworkSettingsUnsupported(t, configWalletSettings(nil, failedDashboardReader{}, io.Discard), "")
	assertNetworkSettingsUnsupported(t, configWalletSettings(nil, strings.NewReader(valid), failedDashboardWriter{}), "")
}
