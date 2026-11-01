package cli

import (
	"bytes"
	"io"
	"strings"
	"testing"
)

func TestConfigPayoutOwnershipProtocol(t *testing.T) {
	private := "01" + strings.Repeat("00", 31)
	public := "5866666666666666666666666666666666666666666666666666666666666666"
	frame := "monero\x00" + public + "\x00" + private + "\x00\x00https://docs\x000\x00"
	var output bytes.Buffer
	if err := configPayoutOwnership(nil, strings.NewReader(frame), &output); err != nil {
		t.Fatalf("configPayoutOwnership() error: %v", err)
	}
	if output.String() != "0\x00\x00\x00" {
		t.Fatalf("configPayoutOwnership() = %q", output.String())
	}
}

func TestConfigPayoutOwnershipRefusals(t *testing.T) {
	private := "01" + strings.Repeat("00", 31)
	valid := "monero\x00keys\x00" + private + "\x00\x00https://docs\x000\x00"
	frames := []string{"", strings.TrimSuffix(valid, "\x00"), valid + "extra", valid + "\x00", strings.Replace(valid, "\x000\x00", "\x001\x00", 1), strings.Replace(valid, "monero", "unknown", 1)}
	for _, frame := range frames {
		var output bytes.Buffer
		assertNetworkSettingsUnsupported(t, configPayoutOwnership(nil, strings.NewReader(frame), &output), output.String())
	}
	for _, args := range [][]string{{"extra"}, {"one", "two"}} {
		var output bytes.Buffer
		assertNetworkSettingsUnsupported(t, configPayoutOwnership(args, strings.NewReader(valid), &output), output.String())
	}
	assertNetworkSettingsUnsupported(t, configPayoutOwnership(nil, failedDashboardReader{}, io.Discard), "")
	assertNetworkSettingsUnsupported(t, configPayoutOwnership(nil, strings.NewReader(valid), failedDashboardWriter{}), "")
	assertNetworkSettingsUnsupported(t, configPayoutOwnership(nil, strings.NewReader(valid), shortMaskedWriter{}), "")
}
