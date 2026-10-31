package doctor

import (
	"errors"
	"testing"
)

func TestConfigDiagnosticsGates(t *testing.T) {
	for _, input := range []ConfigDiagnostics{
		{Monero: "\x00", Tari: "\x00", Variant: "\x00", SSHEnabled: "\x00"},
		{Present: true, Variant: "\x00", SSHEnabled: "\x00"},
		{Present: true, Appliance: true, Variant: "debug", SSHEnabled: "\x00"},
		{Present: true, Monero: "your_monero_wallet_address\n", Tari: "your_tari_wallet_address\n"},
	} {
		got, err := input.Findings()
		if err != nil || len(got) != 0 {
			t.Fatalf("Findings(%#v) = %#v, %v", input, got, err)
		}
	}
}

func TestConfigDiagnosticsReachedNUL(t *testing.T) {
	for _, input := range []ConfigDiagnostics{
		{Present: true, Monero: "\x00"},
		{Present: true, Tari: "\x00"},
		{Present: true, Appliance: true, Variant: "\x00"},
		{Present: true, Appliance: true, Variant: "release", SSHEnabled: "\x00"},
		{Present: true, Monero: "4🐢"},
		{Present: true, Monero: "4\xff"},
	} {
		got, err := input.Findings()
		if !errors.Is(err, ErrUnsupportedProbeInput) || got != nil {
			t.Fatalf("Findings(%#v) = %#v, %v", input, got, err)
		}
	}
}

func TestConfigDiagnosticsOrder(t *testing.T) {
	got, err := (ConfigDiagnostics{
		Present: true, Appliance: true, Variant: "release\n", SSHEnabled: "true\n",
		Monero: "invalid", Tari: "invalid", VerifyAddresses: false,
	}).Findings()
	if err != nil || len(got) != 3 {
		t.Fatalf("Findings() = %#v, %v", got, err)
	}
	for index, id := range []string{"ssh-release", "monero-address-type", "tari-address-type"} {
		if got[index].ID != id {
			t.Fatalf("finding %d = %#v", index, got[index])
		}
	}
	if got[0].Status != "warn" || got[1].Status != "warn" || got[2].Status != "info" {
		t.Fatalf("Findings() = %#v", got)
	}
}
