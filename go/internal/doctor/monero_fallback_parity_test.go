//go:build parity

package doctor

import (
	"errors"
	"strings"
	"testing"
)

func TestMoneroParityNumericFallback(t *testing.T) {
	for _, value := range []string{"1.5", "1e1", "-0", "-0.0", "9007199254740992"} {
		t.Run("count/"+value, func(t *testing.T) {
			input := newMoneroParityFixture(t)
			input.write(t, "peers.value", `{"outgoing":`+value+`,"incoming":2}`)
			want := input.reference(t, "counts")
			if want.code != 0 {
				t.Fatal("Bash count oracle failed")
			}
			_, err := input.PeerCounts()
			if !errors.Is(err, ErrUnsupportedProbeInput) {
				t.Fatal("expected fallback for numeric formatting")
			}
		})
	}
	for _, value := range []string{"199900.0", "1.999e5", "199900.5", "1e1000000000"} {
		t.Run("timestamp/"+value, func(t *testing.T) {
			input := newMoneroParityFixture(t)
			input.write(t, "header.value", `{"result":{"block_header":{"timestamp":`+value+`}}}`)
			want := input.reference(t, "peers")
			if want.code != 0 {
				t.Fatal("Bash tip oracle failed")
			}
			_, err := input.PeersAndTip()
			if !errors.Is(err, ErrUnsupportedProbeInput) {
				t.Fatal("expected fallback for numeric formatting")
			}
		})
	}
}

func TestMoneroParityDiagnosticFallback(t *testing.T) {
	for _, field := range []string{"running", "info", "header", "peers"} {
		for _, code := range []string{"0", "7"} {
			t.Run(field+"/"+code, func(t *testing.T) {
				input := newMoneroParityFixture(t)
				input.write(t, field+".value", "\x00{}")
				input.write(t, field+".code", code)
				want := input.reference(t, "sync")
				if !strings.Contains(want.stderr, "null byte") {
					t.Fatal("Bash did not expose the NUL diagnostic")
				}
				_, err := input.Findings()
				if !errors.Is(err, ErrUnsupportedProbeInput) {
					t.Fatal("expected fallback for an exposed diagnostic")
				}
			})
		}
	}
}

func TestMoneroParityJSONFallback(t *testing.T) {
	for name, value := range map[string]string{
		"surrogate":         `{"status":"OK","synchronized":true,"extra":"\ud800"}`,
		"escape":            `{"status":"\u004fK","synchronized":true}`,
		"encoding":          "{\"status\":\"OK\",\"synchronized\":true,\"extra\":\"\xff\"}",
		"nan":               `{"status":"OK","synchronized":true,"extra":NaN}`,
		"infinity":          `{"status":"OK","synchronized":true,"extra":Infinity}`,
		"negative-infinity": `{"status":"OK","synchronized":true,"extra":-Infinity}`,
		"invalid":           `not-json`,
	} {
		t.Run(name, func(t *testing.T) {
			input := newMoneroParityFixture(t)
			input.write(t, "info.value", value)
			want := input.reference(t, "sync")
			if want.code != 0 {
				t.Fatal("Bash JSON oracle failed")
			}
			_, err := input.Findings()
			if !errors.Is(err, ErrUnsupportedProbeInput) {
				t.Fatal("expected fallback for JSON encoding")
			}
		})
	}
}
