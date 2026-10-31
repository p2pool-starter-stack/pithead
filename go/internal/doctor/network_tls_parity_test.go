//go:build parity

package doctor

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestNetworkTLSNormalizationTools(t *testing.T) {
	for _, body := range []string{"printf true; exit 1", "printf TRUE; exit 0", "printf 'yes\\n\\n'; exit 7", "exit 0"} {
		input := newNetworkFixture(t)
		networkToolFixture(t, input, "ip", "2: eth0 inet 203.0.113.5/24\n", 0)
		input.Password = "fixture-password"
		if err := os.Remove(filepath.Join(input.Bin, "tr")); err != nil {
			t.Fatal(err)
		}
		writeHostTool(t, input.Bin, "tr", body+"\n")
		compareNetwork(t, input, "exposure")
	}
	for _, mode := range []string{"missing", "diagnostic"} {
		input := newNetworkFixture(t)
		networkToolFixture(t, input, "ip", "2: eth0 inet 203.0.113.5/24\n", 0)
		if err := os.Remove(filepath.Join(input.Bin, "tr")); err != nil {
			t.Fatal(err)
		}
		if mode == "diagnostic" {
			writeHostTool(t, input.Bin, "tr", "printf 'fixture diagnostic\\n' >&2\nprintf true\n")
		}
		result := runNetworkBash(t, input, "exposure")
		if result.code != 0 || (mode == "missing" && !strings.Contains(result.stderr, "tr:")) || (mode == "diagnostic" && !strings.Contains(result.stderr, "fixture diagnostic")) {
			t.Fatalf("Bash %s tr diagnostic missing: %+v", mode, result)
		}
		if _, err := input.Findings(); !errors.Is(err, ErrUnsupportedProbeInput) {
			t.Fatalf("%s tr: error = %v", mode, err)
		}
	}
}
