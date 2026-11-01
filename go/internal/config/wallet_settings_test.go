package config

import (
	"errors"
	"testing"
)

func TestParseWalletSettings(t *testing.T) {
	tests := []struct {
		name, raw, mode, path string
		want                  WalletSettings
	}{
		{"values", `{"monero":{"wallet_address":"monero"},"tari":{"wallet_address":"tari"}}`, "local", "/stack/config.json", WalletSettings{Assigned: 2, MoneroWallet: "monero", TariWallet: "tari"}},
		{"off without tari", `{"monero":{"wallet_address":"monero"}}`, "off", "/stack/config.json", WalletSettings{Assigned: 2, MoneroWallet: "monero"}},
		{"bad mode before document", `{`, "invalid", "/stack/config.json", WalletSettings{Reason: `tari.mode must be "local", "remote" or "off" (got "invalid").`}},
		{"missing monero", `{"tari":{"wallet_address":"tari"}}`, "local", "/stack/config.json", WalletSettings{Assigned: 2, TariWallet: "tari", Reason: "Missing required wallet addresses in /stack/config.json."}},
		{"missing tari", `{"monero":{"wallet_address":"monero"}}`, "remote", "config.json", WalletSettings{Assigned: 2, MoneroWallet: "monero", Reason: "Missing required wallet addresses in config.json."}},
		{"space", `{"monero":{"wallet_address":"monero"},"tari":{"wallet_address":"tari address"}}`, "local", "config.json", WalletSettings{Assigned: 2, MoneroWallet: "monero", TariWallet: "tari address", Reason: "tari.wallet_address contains whitespace — a Tari address (base58 or emoji) has none. Check for a stray space or line break in config.json."}},
		{"ascii whitespace", `{"monero":{"wallet_address":true},"tari":{"wallet_address":"tari\taddress"}}`, "local", "config.json", WalletSettings{Assigned: 2, MoneroWallet: "true", TariWallet: "tari\taddress", Reason: "tari.wallet_address contains whitespace — a Tari address (base58 or emoji) has none. Check for a stray space or line break in config.json."}},
		{"trailing line feed", `{"monero":{"wallet_address":"monero"},"tari":{"wallet_address":"tari\n"}}`, "local", "config.json", WalletSettings{Assigned: 2, MoneroWallet: "monero", TariWallet: "tari"}},
		{"multiple trailing line feeds", `{"monero":{"wallet_address":"monero\n\n"},"tari":{"wallet_address":"tari"}}`, "local", "config.json", WalletSettings{Assigned: 2, MoneroWallet: "monero", TariWallet: "tari"}},
		{"only line feeds", `{"monero":{"wallet_address":"monero"},"tari":{"wallet_address":"\n\n"}}`, "local", "config.json", WalletSettings{Assigned: 2, MoneroWallet: "monero", Reason: "Missing required wallet addresses in config.json."}},
		{"emoji", `{"monero":{"wallet_address":7},"tari":{"wallet_address":"😀🌟"}}`, "local", "config.json", WalletSettings{Assigned: 2, MoneroWallet: "7", TariWallet: "😀🌟"}},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			got, err := ParseWalletSettings([]byte(test.raw), test.mode, test.path)
			if err != nil || got != test.want {
				t.Fatalf("ParseWalletSettings() = %#v, %v; want %#v, nil", got, err, test.want)
			}
		})
	}
}

func TestParseWalletSettingsRejectUnsupported(t *testing.T) {
	tests := []string{
		`{`, `{"monero":{},"monero":{}}`, `{"monero":[]}`,
		`{"monero":{"wallet_address":{}}}`, `{"monero":{"wallet_address":1.5}}`,
		`{"monero":{"wallet_address":"address\u0000"}}`,
		`{"monero":{"wallet_address":"monero"},"tari":{"wallet_address":"tari\u00a0address"}}`,
	}
	for _, raw := range tests {
		got, err := ParseWalletSettings([]byte(raw), "local", "config.json")
		if got != (WalletSettings{}) || !errors.Is(err, ErrUnsupportedValidation) {
			t.Fatalf("ParseWalletSettings(%q) = %#v, %v", raw, got, err)
		}
	}
	got, err := ParseWalletSettings([]byte{0xff}, "local", "config.json")
	if got != (WalletSettings{}) || !errors.Is(err, ErrUnsupportedValidation) {
		t.Fatalf("ParseWalletSettings(invalid UTF-8) = %#v, %v", got, err)
	}
}
