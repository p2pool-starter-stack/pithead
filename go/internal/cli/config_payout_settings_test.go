package cli

import (
	"bytes"
	"io"
	"strings"
	"testing"
)

func TestConfigPayoutSettingsProtocol(t *testing.T) {
	key := strings.Repeat("a", 64)
	tests := []struct {
		mode, frame, want string
	}{
		{"monero", `{"monero":{"view_key":"` + key + `","payout_scan_height":"12"}}` + "\x00https://docs\x000\x00", "4\x00local\x00" + key + "\x0012\x00true\x00\x00"},
		{"tari", `{"tari":{"view_key":"` + key + `","spend_public_key":"spend","payout_scan_birthday":"10"}}` + "\x00local\x00https://docs\x000\x00", key + "\x00spend\x0010\x00false\x00\x00"},
		{"birthday", "1760\x001765\x000\x00", "\x00"},
		{"birthday", "1766\x001765\x000\x00", "tari.payout_scan_birthday must be days since 2022-01-01 (Tari's wallet birthday), no later than today (1765). Got \"1766\"; a days-since-1970 value is too large.\x00"},
	}
	for _, test := range tests {
		var output bytes.Buffer
		if err := configPayoutSettings([]string{test.mode}, strings.NewReader(test.frame), &output); err != nil {
			t.Fatalf("configPayoutSettings(%q) error: %v", test.mode, err)
		}
		if output.String() != test.want {
			t.Fatalf("configPayoutSettings(%q) = %q; want %q", test.mode, output.String(), test.want)
		}
	}
}

func TestConfigPayoutSettingsRefusals(t *testing.T) {
	valid := map[string]string{
		"monero":   "{}\x00https://docs\x000\x00",
		"tari":     "{}\x00local\x00https://docs\x000\x00",
		"birthday": "10\x001765\x000\x00",
	}
	for mode, frame := range valid {
		frames := []string{
			"", strings.TrimSuffix(frame, "\x00"), frame + "extra", frame + "\x00",
			strings.TrimSuffix(frame, "0\x00") + "1\x00",
			strings.TrimSuffix(frame, "0\x00") + "00\x00",
		}
		for _, candidate := range frames {
			var output bytes.Buffer
			assertNetworkSettingsUnsupported(t, configPayoutSettings([]string{mode}, strings.NewReader(candidate), &output), output.String())
		}
	}
	for _, args := range [][]string{nil, {"unknown"}, {"monero", "extra"}} {
		var output bytes.Buffer
		assertNetworkSettingsUnsupported(t, configPayoutSettings(args, strings.NewReader(valid["monero"]), &output), output.String())
	}
	assertNetworkSettingsUnsupported(t, configPayoutSettings([]string{"monero"}, failedDashboardReader{}, io.Discard), "")
	assertNetworkSettingsUnsupported(t, configPayoutSettings([]string{"monero"}, strings.NewReader(valid["monero"]), failedDashboardWriter{}), "")
}
