package config

import (
	"errors"
	"strings"
	"testing"
)

const payoutDocs = "https://example.test/pithead"

func TestParseMoneroPayoutSettings(t *testing.T) {
	key := strings.Repeat("a", 64)
	tests := []struct {
		name string
		raw  string
		want MoneroPayoutSettings
	}{
		{"defaults", `{}`, MoneroPayoutSettings{Assigned: 4, Mode: "local", ScanHeight: "auto", Enabled: "false"}},
		{"enabled", `{"monero":{"mode":"local","view_key":"` + key + `","payout_scan_height":"00123"}}`, MoneroPayoutSettings{Assigned: 4, Mode: "local", ViewKey: key, ScanHeight: "00123", Enabled: "true"}},
		{"bad mode", `{"monero":{"mode":"off","view_key":[]}}`, MoneroPayoutSettings{Assigned: 1, Mode: "off", Reason: `monero.mode must be "local" or "remote" (got "off").`}},
		{"remote key", `{"monero":{"mode":"remote","view_key":"` + key + `"}}`, MoneroPayoutSettings{Assigned: 4, Mode: "remote", ViewKey: key, ScanHeight: "auto", Enabled: "false", Reason: `monero.view_key is set but monero.mode is "remote". On-chain payout confirmation scans against the LOCAL node only — a remote/third-party daemon changes the trust story. Unset monero.view_key, or switch to a local node.`}},
		{"bad key", `{"monero":{"view_key":"ABC"}}`, MoneroPayoutSettings{Assigned: 4, Mode: "local", ViewKey: "ABC", ScanHeight: "auto", Enabled: "false", Reason: "monero.view_key must be the 64-character hex SECRET VIEW KEY for monero.wallet_address (Monero GUI: Settings › Wallet › Show seed & keys › 'Secret view key'; monero-wallet-cli: viewkey). See " + payoutDocs + "/docs/dashboard.md#getting-your-view-keys. Got 3 chars."}},
		{"bad height", `{"monero":{"view_key":"` + key + `","payout_scan_height":"1e3"}}`, MoneroPayoutSettings{Assigned: 4, Mode: "local", ViewKey: key, ScanHeight: "1e3", Enabled: "false", Reason: `monero.payout_scan_height must be "auto" or a block height (integer).`}},
		{"numeric height", `{"monero":{"view_key":"` + key + `","payout_scan_height":-1}}`, MoneroPayoutSettings{Assigned: 4, Mode: "local", ViewKey: key, ScanHeight: "-1", Enabled: "false", Reason: `monero.payout_scan_height must be "auto" or a block height (integer).`}},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			got, err := ParseMoneroPayoutSettings([]byte(test.raw), payoutDocs)
			if err != nil || got != test.want {
				t.Fatalf("ParseMoneroPayoutSettings() = %#v, %v; want %#v, nil", got, err, test.want)
			}
		})
	}
}

func TestParseTariPayoutSettings(t *testing.T) {
	key := strings.Repeat("b", 64)
	tests := []struct {
		name, raw, mode string
		want            TariPayoutSettings
	}{
		{"defaults", `{}`, "local", TariPayoutSettings{Birthday: "auto", Enabled: "false"}},
		{"values", `{"tari":{"view_key":"` + key + `","spend_public_key":"spend","payout_scan_birthday":"1425"}}`, "local", TariPayoutSettings{ViewKey: key, SpendPublicKey: "spend", Birthday: "1425", Enabled: "false"}},
		{"numeric inert values", `{"tari":{"spend_public_key":7,"payout_scan_birthday":1999}}`, "local", TariPayoutSettings{SpendPublicKey: "7", Birthday: "1999", Enabled: "false"}},
		{"remote", `{"tari":{"view_key":"` + key + `"}}`, "remote", TariPayoutSettings{ViewKey: key, Birthday: "auto", Enabled: "false", Reason: `tari.view_key is set but tari.mode is "remote". Payout confirmation scans the LOCAL Tari node, so it needs tari.mode: local — unset tari.view_key, or use a local Tari node.`}},
		{"bad key", `{"tari":{"view_key":"nope"}}`, "local", TariPayoutSettings{ViewKey: "nope", Birthday: "auto", Enabled: "false", Reason: "tari.view_key must be the 64-character hex PRIVATE VIEW KEY for the Tari payout address (Tari Universe: 'view_private_key_hex' in config_wallet.json; minotari_console_wallet: export-view-key-and-spend-key). See " + payoutDocs + "/docs/dashboard.md#getting-your-view-keys. Got 4 chars."}},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			got, err := ParseTariPayoutSettings([]byte(test.raw), test.mode, payoutDocs)
			if err != nil || got != test.want {
				t.Fatalf("ParseTariPayoutSettings() = %#v, %v; want %#v, nil", got, err, test.want)
			}
		})
	}
}

func TestPayoutSettingsRejectUnsupported(t *testing.T) {
	monero := []string{
		`{`, `{"monero":{},"monero":{}}`, `{"monero":[]}`,
		`{"monero":{"payout_scan_height":1.5}}`, `{"monero":{"view_key":"é"}}`,
	}
	for _, raw := range monero {
		got, err := ParseMoneroPayoutSettings([]byte(raw), payoutDocs)
		if got != (MoneroPayoutSettings{}) || !errors.Is(err, ErrUnsupportedValidation) {
			t.Fatalf("ParseMoneroPayoutSettings(%q) = %#v, %v", raw, got, err)
		}
	}
	tari := []string{
		`{`, `{"tari":{},"tari":{}}`, `{"tari":[]}`,
		`{"tari":{"view_key":[]}}`, `{"tari":{"payout_scan_birthday":1e2}}`,
		`{"tari":{"view_key":"a\nb"}}`,
	}
	for _, raw := range tari {
		got, err := ParseTariPayoutSettings([]byte(raw), "local", payoutDocs)
		if got != (TariPayoutSettings{}) || !errors.Is(err, ErrUnsupportedValidation) {
			t.Fatalf("ParseTariPayoutSettings(%q) = %#v, %v", raw, got, err)
		}
	}
}

func TestValidatePayoutBirthday(t *testing.T) {
	tests := []struct {
		birthday, today, want string
	}{
		{"", "1765", ""},
		{"auto", "1765", ""},
		{"00123", "1765", ""},
		{"height-1", "1765", `tari.payout_scan_birthday must be "auto" or DAYS SINCE 2022-01-01 (Tari's wallet birthday; Tari Universe's wallet_birthday works as-is), NOT a block height. Got "height-1".`},
		{"1766", "1765", `tari.payout_scan_birthday must be days since 2022-01-01 (Tari's wallet birthday), no later than today (1765). Got "1766"; a days-since-1970 value is too large.`},
		{"999999", "1765", `tari.payout_scan_birthday must be days since 2022-01-01 (Tari's wallet birthday), no later than today (1765). Got "999999"; a days-since-1970 value is too large.`},
	}
	for _, test := range tests {
		got, err := ValidatePayoutBirthday(test.birthday, test.today)
		if err != nil || got != test.want {
			t.Fatalf("ValidatePayoutBirthday(%q, %q) = %q, %v; want %q, nil", test.birthday, test.today, got, err, test.want)
		}
	}
	for _, input := range [][2]string{{"é", "1765"}, {"1", "01765"}, {"1", "+1765"}, {"1", "9223372036854775808"}} {
		if got, err := ValidatePayoutBirthday(input[0], input[1]); got != "" || !errors.Is(err, ErrUnsupportedValidation) {
			t.Fatalf("ValidatePayoutBirthday(%q, %q) = %q, %v", input[0], input[1], got, err)
		}
	}
}
