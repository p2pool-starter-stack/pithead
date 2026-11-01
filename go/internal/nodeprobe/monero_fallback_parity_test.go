//go:build parity

package nodeprobe

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestMoneroRPCParityJSONFallback(t *testing.T) {
	for name, body := range map[string]string{
		"decimal":    `{"status":"OK","nettype":"mainnet","height":10.0,"target_height":20}`,
		"exponent":   `{"status":"OK","nettype":"mainnet","height":1e1,"target_height":20}`,
		"fraction":   `{"status":"OK","nettype":"mainnet","height":1.5,"target_height":20}`,
		"minus-zero": `{"status":"OK","nettype":"mainnet","height":-0,"target_height":20}`,
		"huge":       `{"status":"OK","nettype":"mainnet","height":9007199254740992,"target_height":20}`,
		"escape":     `{"status":"\u004fK","nettype":"mainnet","height":10,"target_height":20}`,
		"surrogate":  `{"status":"OK","nettype":"mainnet","height":10,"target_height":20,"extra":"\ud800"}`,
		"nan":        `{"status":"OK","nettype":"mainnet","height":10,"target_height":20,"extra":NaN}`,
		"infinity":   `{"status":"OK","nettype":"mainnet","height":10,"target_height":20,"extra":Infinity}`,
		"encoding":   "{\"status\":\"OK\",\"nettype\":\"mainnet\",\"height\":10,\"target_height\":20,\"extra\":\"\xff\"}",
		"malformed":  `not-json`,
		"multiple":   `{"status":"OK","nettype":"mainnet","height":10,"target_height":20} {}`,
	} {
		t.Run(name, func(t *testing.T) {
			fixture := newRPCFixture(t)
			fixture.write(t, "response.value", body+"\n200")
			want, _ := fixture.reference(t)
			if want.result != "0\nok\n" && want.result != "1\nprotocol\n" {
				t.Fatal("unexpected Bash JSON classification")
			}
			if _, err := fixture.Check(); !errors.Is(err, ErrUnsupportedProbeInput) {
				t.Fatal("expected fallback for jq-specific JSON semantics")
			}
		})
	}
}

func TestMoneroRPCParityNULFallback(t *testing.T) {
	for _, code := range []string{"0", "7"} {
		t.Run(code, func(t *testing.T) {
			fixture := newRPCFixture(t)
			fixture.write(t, "response.value", "\x00{}\n200")
			fixture.write(t, "curl.code", code)
			_, diagnostic := fixture.reference(t)
			if !strings.Contains(diagnostic, "null byte") {
				t.Fatal("Bash did not expose the NUL diagnostic")
			}
			if _, err := fixture.Check(); !errors.Is(err, ErrUnsupportedProbeInput) {
				t.Fatal("expected fallback for an exposed shell diagnostic")
			}
		})
	}
}

func TestMoneroRPCParityLaunchFallback(t *testing.T) {
	for _, name := range []string{"permission", "no-shebang"} {
		t.Run(name, func(t *testing.T) {
			fixture := newRPCFixture(t)
			path := filepath.Join(fixture.dir, "timeout")
			if err := os.WriteFile(path, []byte("exit 7\n"), 0o755); err != nil {
				t.Fatal(err)
			}
			if name == "permission" {
				if err := os.Chmod(path, 0o600); err != nil {
					t.Fatal(err)
				}
			}
			want, _ := fixture.reference(t)
			if want.result != "1\nunknown\n" && want.result != "1\nrefused\n" {
				t.Fatal("unexpected Bash launch classification")
			}
			if _, err := fixture.Check(); !errors.Is(err, ErrUnsupportedProbeInput) {
				t.Fatal("expected fallback for an unsupported tool launch")
			}
		})
	}
}
