package config

import (
	"errors"
	"strings"
	"testing"
)

func TestValidateWorkers(t *testing.T) {
	tests := []struct {
		name        string
		raw         string
		want        string
		wantWarning bool
		unsupported bool
	}{
		{"empty", `{}`, "", false, false},
		{"false workers", `{"workers":false}`, "", false, false},
		{"fleet port lexical", `{"workers":{"api_port":8000.0}}`, "", false, true},
		{"fleet port exponent", `{"workers":{"api_port":8e3}}`, "", false, true},
		{"fleet port negative zero", `{"workers":{"api_port":-0}}`, "", false, true},
		{"fleet port negative", `{"workers":{"api_port":-1}}`, "workers.api_port must be an integer between 1 and 65535 (the fleet default worker API port).", false, false},
		{"fleet port zero", `{"workers":{"api_port":0}}`, "workers.api_port must be an integer between 1 and 65535 (the fleet default worker API port).", false, false},
		{"list shape", `{"workers":{"list":{}}}`, "workers.list must be an array of {name, host?, port?, token?, api_token?} objects.", false, false},
		{"entry shape", `{"workers":{"list":[null]}}`, "workers.list entries must be objects (got a null).", false, false},
		{"name", `{"workers":{"list":[{}]}}`, `workers.list: every entry needs a "name" of 1-128 printable non-space characters (its stratum worker name).`, false, false},
		{"host", `{"workers":{"list":[{"name":"rig","host":"host:1"}]}}`, "workers.list[rig].host must be a hostname or IPv4 address (letters, digits, and . _ - only; no port or path).", false, false},
		{"integral exponent port", `{"workers":{"list":[{"name":"rig","port":8e3}]}}`, "", false, false},
		{"ambiguous precision port", `{"workers":{"list":[{"name":"rig","port":1.0000000000000000000001}]}}`, "", false, true},
		{"fraction port", `{"workers":{"list":[{"name":"rig","port":1.5}]}}`, "workers.list[rig].port must be an integer between 1 and 65535.", false, false},
		{"control port", `{"workers":{"list":[{"name":"rig","control_port":0}]}}`, "workers.list[rig].control_port must be an integer between 1 and 65535 (the rig writable control API port, #185).", false, false},
		{"token", `{"workers":{"list":[{"name":"rig","token":"has space"}]}}`, "workers.list[rig].token must be 1-128 printable non-space characters.", false, false},
		{"api token host", `{"workers":{"list":[{"name":"rig","api_token":"secret"}]}}`, "workers.list[rig].api_token needs an operator-set host and 1-128 printable non-space characters.", false, false},
		{"watts", `{"workers":{"list":[{"name":"rig","watts":1000000}]}}`, "workers.list[rig].watts must be a positive number of watts (a manual power-draw estimate for the energy calculator, #260).", false, false},
		{"duplicate sort", `{"workers":{"list":[{"name":"z"},{"name":"a"},{"name":"z"},{"name":"a"}]}}`, "workers.list has duplicate names (a, z) — the first-declared entry wins; a renamed rig needs its config entry updated.", true, false},
		{"regex control fallback", `{"workers":{"list":[{"name":"rig\nother"}]}}`, "", false, true},
		{"scalar parent", `{"workers":1}`, "", false, true},
		{"overflow", `{"workers":{"list":[{"name":"rig","watts":1e999}]}}`, "", false, true},
		{"ambiguous watts boundary", `{"workers":{"list":[{"name":"rig","watts":999999.9999999999999999}]}}`, "", false, true},
		{"decimal watts underflow", `{"workers":{"list":[{"name":"rig","watts":0.` + strings.Repeat("0", 400) + `1}]}}`, "", false, true},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			reason, warning, err := ValidateSection([]byte(test.raw), "workers")
			if reason != test.want || warning != test.wantWarning || errors.Is(err, ErrUnsupportedValidation) != test.unsupported {
				t.Fatalf("ValidateSection() = %q, %v, %v", reason, warning, err)
			}
		})
	}
}

func TestValidateEnergy(t *testing.T) {
	tests := []struct {
		name        string
		raw         string
		want        string
		unsupported bool
	}{
		{"empty", `{}`, "", false},
		{"false energy", `{"dashboard":{"energy":false}}`, "", false},
		{"shape", `{"dashboard":{"energy":[]}}`, "dashboard.energy must be an object {cost_per_kwh, currency?, xmr_price?, tari_price?, price_feed?}.", false},
		{"unknown sorted", `{"dashboard":{"energy":{"z":0,"a":0}}}`, "dashboard.energy has an unknown key (a, z). Only cost_per_kwh, currency, xmr_price, tari_price and price_feed are allowed.", false},
		{"decimal", `{"dashboard":{"energy":{"cost_per_kwh":0.125,"xmr_price":1e3,"tari_price":-0}}}`, "", false},
		{"negative cost", `{"dashboard":{"energy":{"cost_per_kwh":-0.1}}}`, "dashboard.energy.cost_per_kwh must be a non-negative number (your electricity price per kWh; 0 or unset hides the profit math).", false},
		{"negative xmr", `{"dashboard":{"energy":{"xmr_price":-1}}}`, "dashboard.energy.xmr_price must be a non-negative number (the fiat price of 1 XMR in your currency; 0 or unset hides net profit).", false},
		{"negative tari", `{"dashboard":{"energy":{"tari_price":-1}}}`, "dashboard.energy.tari_price must be a non-negative number (the fiat price of 1 XTM in your currency; 0 or unset excludes Tari from net profit).", false},
		{"currency", `{"dashboard":{"energy":{"currency":"US D"}}}`, "dashboard.energy.currency must be a short currency label (e.g. USD, EUR).", false},
		{"price feed", `{"dashboard":{"energy":{"price_feed":1}}}`, "dashboard.energy.price_feed must be true or false (fetch live XMR/XTM prices from CoinGecko over Tor; default false, no clearnet egress).", false},
		{"scalar dashboard", `{"dashboard":true}`, "", true},
		{"overflow", `{"dashboard":{"energy":{"xmr_price":1e999}}}`, "", true},
		{"underflow", `{"dashboard":{"energy":{"cost_per_kwh":-1e-999}}}`, "", true},
		{"decimal underflow", `{"dashboard":{"energy":{"cost_per_kwh":-0.` + strings.Repeat("0", 400) + `1}}}`, "", true},
		{"control key", `{"dashboard":{"energy":{"bad\u0000key":1}}}`, "", true},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			reason, warning, err := ValidateSection([]byte(test.raw), "energy")
			if reason != test.want || warning || errors.Is(err, ErrUnsupportedValidation) != test.unsupported {
				t.Fatalf("ValidateSection() = %q, %v, %v", reason, warning, err)
			}
		})
	}
}

func TestValidateWebhooksAndControls(t *testing.T) {
	tests := []struct {
		name        string
		section     string
		raw         string
		want        string
		unsupported bool
	}{
		{"webhooks absent", "webhooks", `{}`, "", false},
		{"webhooks shape", "webhooks", `{"notifications":{"webhooks":false}}`, "notifications.webhooks must be an array of URL strings.", false},
		{"webhooks member", "webhooks", `{"notifications":{"webhooks":["https://example",null]}}`, "notifications.webhooks[1] must be a URL string; null and other non-string members are not allowed.", false},
		{"webhooks scalar parent", "webhooks", `{"notifications":false}`, "", true},
		{"controls clean", "controls", `{"key":"value\u00a0"}`, "", false},
		{"controls c0", "controls", `{"key":"value\n"}`, "control character", false},
		{"controls del", "controls", `{"key":"value\u007f"}`, "control character", false},
		{"controls c1", "controls", `{"key":"value\u0085"}`, "control character", false},
		{"controls keys ignored", "controls", `{"bad\nkey":"value"}`, "", false},
		{"malformed", "controls", `{"key":`, "", true},
		{"duplicate", "controls", `{"key":"a","key":"b"}`, "", true},
		{"unknown section", "other", `{}`, "", true},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			reason, warning, err := ValidateSection([]byte(test.raw), test.section)
			if reason != test.want || warning || errors.Is(err, ErrUnsupportedValidation) != test.unsupported {
				t.Fatalf("ValidateSection() = %q, %v, %v", reason, warning, err)
			}
		})
	}
}
