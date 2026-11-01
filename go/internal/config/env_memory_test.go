package config

import (
	"errors"
	"strings"
	"testing"
)

func TestMemorySettingsDefaultsAndModes(t *testing.T) {
	tests := []struct {
		name       string
		raw        string
		mode       string
		wantTari   string
		wantMonero string
	}{
		{"local defaults", `{}`, "local", "auto", "6g"},
		{"remote placeholder", `{"tari":4}`, "remote", "0m", "6g"},
		{"off does not read Tari", `{"tari":{"mem_limit":[]}}`, "off", "0m", "6g"},
		{"explicit strings", `{"tari":{"mem_limit":"8g"},"monero":{"mem_limit":"12g"}}`, "local", "8g", "12g"},
		{"empty values", `{"tari":{"mem_limit":""},"monero":{"mem_limit":""}}`, "local", "", "6g"},
		{"null values", `{"tari":{"mem_limit":null},"monero":{"mem_limit":null}}`, "local", "auto", "6g"},
		{"false alternatives", `{"tari":{"mem_limit":false},"monero":{"mem_limit":false}}`, "local", "auto", "6g"},
		{"scalar values", `{"tari":{"mem_limit":8192},"monero":{"mem_limit":true}}`, "local", "8192", "true"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			tari, monero, err := MemorySettings([]byte(test.raw), test.mode)
			if err != nil || tari != test.wantTari || monero != test.wantMonero {
				t.Fatalf("MemorySettings() = %q, %q, %v; want %q, %q, nil", tari, monero, err, test.wantTari, test.wantMonero)
			}
		})
	}
}

func TestMemorySettingsRejectsUnsupportedWithoutExposingInput(t *testing.T) {
	secret := "operator-secret"
	tests := map[string]string{
		"invalid JSON":    `{`,
		"duplicate":       `{"monero":{},"monero":{}}`,
		"scalar parent":   `{"monero":4}`,
		"compound Tari":   `{"tari":{"mem_limit":[]}}`,
		"compound Monero": `{"monero":{"mem_limit":{}}}`,
		"control string":  `{"monero":{"mem_limit":"` + secret + `\n"}}`,
		"decimal":         `{"monero":{"mem_limit":6.0}}`,
		"unsafe integer":  `{"monero":{"mem_limit":9007199254740992}}`,
	}
	for name, raw := range tests {
		t.Run(name, func(t *testing.T) {
			tari, monero, err := MemorySettings([]byte(raw), "local")
			if tari != "" || monero != "" || !errors.Is(err, ErrUnsupportedMemory) {
				t.Fatalf("MemorySettings() = %q, %q, %v; want empty, empty, unsupported", tari, monero, err)
			}
			if strings.Contains(err.Error(), secret) {
				t.Fatalf("error exposes input: %q", err)
			}
		})
	}
}

func TestTariMemoryLimit(t *testing.T) {
	tests := []struct {
		name string
		ram  string
		huge string
		want string
	}{
		{"unknown host", "", "", "12288m"},
		{"zero RAM", "0", "0", "12288m"},
		{"negative RAM", "-1", "0", "12288m"},
		{"negative huge pages", "16384", "-1", "12288m"},
		{"8 GB", "8192", "0", "6144m"},
		{"16 GB", "16384", "0", "12288m"},
		{"16 GB with huge pages", "16384", "6144", "7680m"},
		{"32 GB with huge pages", "32768", "6144", "19968m"},
		{"low RAM floor", "1024", "0", "2048m"},
		{"huge pages exceed RAM", "4096", "8192", "2048m"},
		{"reserve floor", "4096", "0", "2048m"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			got, err := TariMemoryLimit(test.ram, test.huge)
			if err != nil || got != test.want {
				t.Fatalf("TariMemoryLimit(%q, %q) = %q, %v; want %q, nil", test.ram, test.huge, got, err, test.want)
			}
		})
	}
}

func TestTariMemoryLimitRejectsNoncanonicalFacts(t *testing.T) {
	tests := []struct {
		ram  string
		huge string
	}{
		{"00", "0"},
		{"01", "0"},
		{"+1", "0"},
		{"-0", "0"},
		{"1 ", "0"},
		{"1.0", "0"},
		{"9223372036854775808", "0"},
		{"16384", "00"},
	}
	for _, test := range tests {
		got, err := TariMemoryLimit(test.ram, test.huge)
		if got != "" || !errors.Is(err, ErrUnsupportedMemory) {
			t.Errorf("TariMemoryLimit(%q, %q) = %q, %v; want empty, unsupported", test.ram, test.huge, got, err)
		}
	}
}
