package main

import (
	"bytes"
	"strings"
	"testing"
)

func nul(fields ...string) string {
	return strings.Join(fields, "\x00") + "\x00"
}

func TestAddressHelper(t *testing.T) {
	cases := []struct {
		name  string
		input string
		want  string
		code  int
	}{
		{"monero primary", nul("monero", "0", "48edfHu7V9Z84YzzMa6fUueoELZ9ZRXq9VetWzYGzKt52XU5xvqgzYnDK9URnRoJMk1j8nLwEVsaSWJ4fhdUyZijBGUicoD"), "primary", 0},
		{"tari ok", nul("tari", "0", "126J92Yow5y9UoRFd1DNujPmVFq9C1ZeiYWT95UKxz5Y1rzbfjtHg4SCZS1dk83ivzt3m2XRQHTaYUk9SwmyeCvy5BJ"), "ok", 0},
		{"tari network", nul("tari", "0", "f26J92Yow5y9UoRFd1DNujPmVFq9C1ZeiYWT95UKxz5Y1rzbfjtHg4SCZS1dk83ivzt3m2XRQHTaYUk9SwmyeCvy5Cb"), "network", 0},
		{"monero key", nul("monero", "1", "48edfHu7V9Z84YzzMa6fUueoELZ9ZRXq9VetWzYGzKt52XU5xvqgzYnDK9URnRoJMk1j8nLwEVsaSWJ4fhdUyZijBGUicoD"), "1e7f5d11ab6a2f499d2213a0195b670457d9d9637d48cbaf237760b10f0be45b", 0},
		{"tari key single", nul("tari", "1", "1224yPceFvbksLKQ8JE6APDzVY2D6P3SpXwB5LLC3BH4F7oF"), "00d09dfde45e45456b7a8935fecfc0ebea431548d105d2f098a488820526395a61", 0},
		{"empty address", nul("monero", "0", ""), "invalid", 0},
		{"unknown chain", nul("ripple", "0", ""), "", 1},
		{"bad key flag", nul("monero", "2", ""), "", 1},
		{"missing field", nul("monero", "0"), "", 1},
		{"extra field", nul("monero", "0", "", "tail"), "", 1},
		{"trailing bytes", nul("monero", "0", "") + "junk", "", 1},
		{"unterminated", "monero\x000\x00abc", "", 1},
		{"empty input", "", "", 1},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			var out bytes.Buffer
			if got := runAddressHelper(strings.NewReader(tc.input), &out); got != tc.code {
				t.Fatalf("runAddressHelper(%q) code = %d, want %d", tc.input, got, tc.code)
			}
			if got := out.String(); tc.code == 0 && got != tc.want+"\x00" {
				t.Fatalf("runAddressHelper(%q) out = %q, want %q", tc.input, got, tc.want+"\x00")
			}
			if tc.code != 0 && out.Len() != 0 {
				t.Fatalf("runAddressHelper(%q) must stay silent on failure, got %q", tc.input, out.String())
			}
		})
	}
}

func TestDeriveHelper(t *testing.T) {
	cases := []struct {
		name  string
		input string
		want  string
		code  int
	}{
		{"monero", nul("monero", "01"+strings.Repeat("00", 31)), "5866666666666666666666666666666666666666666666666666666666666666", 0},
		{"tari", nul("tari", "02"+strings.Repeat("00", 31)), "6a493210f7499cd17fecb510ae0cea23a110e8d5b901f8acadd3095c73a3b919", 0},
		{"zero scalar", nul("monero", strings.Repeat("00", 32)), "", 1},
		{"bad chain", nul("ripple", "01"+strings.Repeat("00", 31)), "", 1},
		{"bad hex", nul("monero", "zz"), "", 1},
		{"missing field", nul("monero"), "", 1},
		{"extra field", nul("monero", "01"+strings.Repeat("00", 31), "tail"), "", 1},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			var out bytes.Buffer
			if got := runDeriveHelper(strings.NewReader(tc.input), &out); got != tc.code {
				t.Fatalf("runDeriveHelper(%q) code = %d, want %d", tc.input, got, tc.code)
			}
			if got := out.String(); tc.code == 0 && got != tc.want+"\x00" {
				t.Fatalf("runDeriveHelper(%q) out = %q, want %q", tc.input, got, tc.want+"\x00")
			}
			if tc.code != 0 && out.Len() != 0 {
				t.Fatalf("runDeriveHelper(%q) must stay silent on failure, got %q", tc.input, out.String())
			}
		})
	}
}
