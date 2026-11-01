//go:build parity

package doctor

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestTorHistoryDiagnosticFallbackParity(t *testing.T) {
	for _, name := range []string{"id-stderr", "missing-id", "sudo-output", "curl-stdout"} {
		t.Run(name, func(t *testing.T) {
			input := newTorHistoryParityFixture(t)
			operation := "doctor"
			switch name {
			case "id-stderr":
				writeHostTool(t, input.dir, "id", "printf '0\\n'; printf 'fixture notice\\n' >&2\n")
			case "missing-id":
				if err := os.Remove(filepath.Join(input.dir, "id")); err != nil {
					t.Fatal(err)
				}
			case "sudo-output":
				operation = "saturated"
				writeHostTool(t, input.dir, "sudo", "printf 'fixture notice\\n' >&2; exit 1\n")
			case "curl-stdout":
				operation = "egress"
				writeHostTool(t, input.dir, "curl", "printf 'fixture notice\\n'; exit 1\n")
			}
			want := input.reference(t, operation)
			if want.stdout == "" && want.stderr == "" {
				t.Fatal("Bash did not expose the diagnostic")
			}
			var err error
			switch operation {
			case "doctor":
				_, err = input.Findings()
			case "saturated":
				_, err = TorStateSaturated(input.Mount + "/state")
			case "egress":
				_, err = TorRecoveryEgressDown(input.Prefix)
			}
			if !errors.Is(err, ErrUnsupportedProbeInput) {
				t.Fatalf("error = %v; want diagnostic fallback", err)
			}
		})
	}
}

func TestTorHistorySuppressedDiagnosticsParity(t *testing.T) {
	for _, operation := range []string{"doctor", "egress"} {
		t.Run(operation, func(t *testing.T) {
			input := newTorHistoryParityFixture(t)
			writeHostTool(t, input.dir, "curl", "printf 'suppressed\\n' >&2; exit 1\n")
			if operation == "doctor" {
				input.write(t, "id.value", "1000\n")
				path := filepath.Join(input.dir, "sudo")
				body, err := os.ReadFile(path)
				if err != nil {
					t.Fatal(err)
				}
				updated := strings.Replace(string(body), "then exit", "then printf 'suppressed\\n' >&2; exit", 1)
				if err := os.WriteFile(path, []byte(updated), 0o755); err != nil {
					t.Fatal(err)
				}
			}
			compareTorHistory(t, input, operation)
		})
	}
}
