package cli

import (
	"bytes"
	"io"
	"strings"
	"testing"
)

func TestConfigPayoutKeysProtocol(t *testing.T) {
	private := "01" + strings.Repeat("00", 31)
	for _, test := range []struct{ frame, want string }{
		{"monero\x00" + private + "\x000\x00", "0\x005866666666666666666666666666666666666666666666666666666666666666\x00"},
		{"tari\x00" + private + "\x000\x00", "0\x00e2f2ae0a6abc4e71a884a961c500515f58e30b6aa582dd8db6a65945e08d2d76\x00"},
		{"unknown\x00" + private + "\x000\x00", "1\x00\x00"},
		{"monero\x00bad\x000\x00", "1\x00\x00"},
	} {
		var output bytes.Buffer
		if err := configPayoutKeys(nil, strings.NewReader(test.frame), &output); err != nil {
			t.Fatalf("configPayoutKeys(%q) error: %v", test.frame, err)
		}
		if output.String() != test.want {
			t.Fatalf("configPayoutKeys(%q) = %q; want %q", test.frame, output.String(), test.want)
		}
	}
}

func TestConfigPayoutKeysRefusals(t *testing.T) {
	private := "01" + strings.Repeat("00", 31)
	valid := "monero\x00" + private + "\x000\x00"
	for _, frame := range []string{"", strings.TrimSuffix(valid, "\x00"), valid + "extra", valid + "\x00", strings.Replace(valid, "\x000\x00", "\x001\x00", 1)} {
		var output bytes.Buffer
		assertNetworkSettingsUnsupported(t, configPayoutKeys(nil, strings.NewReader(frame), &output), output.String())
	}
	for _, args := range [][]string{{"extra"}, {"one", "two"}} {
		var output bytes.Buffer
		assertNetworkSettingsUnsupported(t, configPayoutKeys(args, strings.NewReader(valid), &output), output.String())
	}
	assertNetworkSettingsUnsupported(t, configPayoutKeys(nil, failedDashboardReader{}, io.Discard), "")
	assertNetworkSettingsUnsupported(t, configPayoutKeys(nil, strings.NewReader(valid), failedDashboardWriter{}), "")
}
