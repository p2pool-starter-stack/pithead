//go:build parity

package doctor

import (
	"errors"
	"os"
	"strings"
	"testing"
)

func TestControlLocalMiner(t *testing.T) {
	for _, marker := range []string{"", "pages=0\n", "pages=1\n", "pages=2048\n", "pages=3071\n", "pages=3072\n", "pages=4096\n", "pages=02560\n", "pages=03072\n", "pages=0000\n", "pages=-1\npages=2560\n", "pages=2560\r\n", "pages=25\x0060\n"} {
		for _, enabled := range []string{"true", "false", "yes", "TRUE", "true\n"} {
			for _, appliance := range []bool{false, true} {
				fixture := newControlFixture(t)
				fixture.input.Appliance = appliance
				if marker != "" {
					if err := os.WriteFile(fixture.marker, []byte(marker), 0o600); err != nil {
						t.Fatal(err)
					}
				}
				result := fixture.reference(t, "miner", enabled, "", "")
				findings, err := (Memory{Marker: fixture.marker, Appliance: appliance}).LocalMiner(enabled)
				if strings.ContainsRune(marker, 0) && appliance && strings.TrimRight(enabled, "\n") == "true" {
					if findings != nil || !errors.Is(err, ErrUnsupportedProbeInput) || result.stdout == "" || result.stderr == "" {
						t.Fatalf("NUL marker: findings=%+v, %v; Bash %+v", findings, err, result)
					}
					continue
				}
				if err != nil {
					t.Fatal(err)
				}
				assertHostFindings(t, result, findings)
			}
		}
	}
}

func TestControlLocalMinerUnsupported(t *testing.T) {
	fixture := newControlFixture(t)
	fixture.input.Appliance = true
	if err := os.WriteFile(fixture.marker, []byte("pages=99999999999999999999999\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	result := fixture.reference(t, "miner", "true", "", "")
	findings, err := (Memory{Marker: fixture.marker, Appliance: true}).LocalMiner("true")
	if findings != nil || !errors.Is(err, ErrUnsupportedProbeInput) || result.stderr == "" {
		t.Fatalf("unsupported findings=%+v, %v; Bash %+v", findings, err, result)
	}
}
