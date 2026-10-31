//go:build parity

package doctor

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestClockSyncStatusParity(t *testing.T) {
	tests := []struct {
		name   string
		output string
		code   string
	}{
		{"yes", "yes", "0"},
		{"no", "no", "0"},
		{"blank", "", "0"},
		{"newlines", "\n\n", "0"},
		{"unknown", "maybe\n", "0"},
		{"whitespace", "yes \n", "0"},
		{"trailing newlines", "yes\n\n", "0"},
		{"failure with output", "yes\n", "7"},
		{"failure without output", "", "7"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			fakeClock(t, test.output, test.code)
			fixture := bashMemory(t, "clock-status", nil, nil, false)
			got, err := ClockSyncStatus()
			if err != nil {
				t.Fatal(err)
			}
			if fixture.code != 0 || fixture.stderr != "" || fixture.stdout != got+"\n" {
				t.Fatalf("Bash = exit %d, stdout %q, stderr %q; Go = %q", fixture.code, fixture.stdout, fixture.stderr, got)
			}
		})
	}
}

func TestClockSyncFindingParity(t *testing.T) {
	for _, appliance := range []bool{false, true} {
		for _, output := range []string{"yes\n", "no\n", "", "unknown\n", "yes \n"} {
			name := fmt.Sprintf("appliance=%t/output=%q", appliance, output)
			t.Run(name, func(t *testing.T) {
				fakeClock(t, output, "0")
				fixture := bashMemory(t, "clock", nil, nil, appliance)
				finding, err := ClockSync(appliance)
				if err != nil {
					t.Fatal(err)
				}
				assertMemoryFinding(t, fixture, []Finding{finding})
			})
		}
	}
}

func TestClockSyncNULBashParity(t *testing.T) {
	fakeClock(t, "", "0")
	tool := filepath.Join(strings.Split(os.Getenv("PATH"), string(os.PathListSeparator))[0], "timedatectl")
	if err := os.WriteFile(tool, []byte("#!/bin/sh\nprintf 'yes\\000\\n'\n"), 0o700); err != nil {
		t.Fatal(err)
	}
	statusFixture := bashMemory(t, "clock-status", nil, nil, false)
	if got, err := ClockSyncStatus(); !errors.Is(err, ErrUnsupportedProbeInput) || got != "" {
		t.Fatalf("Go status = %q, %v", got, err)
	}
	findingFixture := bashMemory(t, "clock", nil, nil, false)
	if got, err := ClockSync(false); !errors.Is(err, ErrUnsupportedProbeInput) || got != (Finding{}) {
		t.Fatalf("Go finding = %#v, %v", got, err)
	}
	if statusFixture.stderr == "" || findingFixture.stderr == "" {
		t.Fatalf("Bash diagnostics missing: status %q, finding %q", statusFixture.stderr, findingFixture.stderr)
	}
}
