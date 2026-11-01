//go:build parity

package doctor

import (
	"errors"
	"strings"
	"testing"
)

func TestContainerParityRevenueDiagnosticFallback(t *testing.T) {
	for _, code := range []string{"0", "1"} {
		t.Run(code, func(t *testing.T) {
			input := newContainerParityFixture(t, "docker")
			input.write(t, "ps.value", "monerod\x00\texited\tExited (1)\n")
			input.write(t, "ps.code", code)
			want := input.reference(t, "revenue")
			if !strings.Contains(want.stderr, "null byte") {
				t.Fatalf("Bash did not expose the diagnostic: %#v", want)
			}
			_, err := (RevenueContainers{}).Findings()
			if !errors.Is(err, ErrUnsupportedProbeInput) {
				t.Fatalf("error = %v; want fallback for Bash diagnostic", err)
			}
		})
	}
}
