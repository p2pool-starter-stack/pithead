//go:build parity

package doctor

import (
	"os"
	"path/filepath"
	"testing"
)

func TestTorHistorySaturationParity(t *testing.T) {
	for _, state := range []struct{ name, value string }{
		{"saturated", "CircuitBuildAbandonedCount 1000\nTotalBuildTimes 1000\n"},
		{"without-final-newline", "CircuitBuildAbandonedCount 1000\nTotalBuildTimes 1000"},
		{"missing-abandoned", "TotalBuildTimes 1000\n"},
		{"missing-total", "CircuitBuildAbandonedCount 1000\n"},
		{"wrong-count", "CircuitBuildAbandonedCount 999\nTotalBuildTimes 1000\n"},
		{"bin", "CircuitBuildAbandonedCount 1000\nTotalBuildTimes 1000\nCircuitBuildTimeBin 10 1\n"},
		{"bin-tab", "CircuitBuildAbandonedCount 1000\nTotalBuildTimes 1000\nCircuitBuildTimeBin\t10 1\n"},
		{"crlf", "CircuitBuildAbandonedCount 1000\r\nTotalBuildTimes 1000\r\n"},
	} {
		t.Run(state.name, func(t *testing.T) {
			input := newTorHistoryParityFixture(t)
			input.write(t, "tor/state", state.value)
			compareTorHistory(t, input, "saturated")
		})
	}
}

func TestTorHistoryStateTypeParity(t *testing.T) {
	for _, kind := range []string{"missing", "directory", "symlink", "dangling", "final-grep-error"} {
		t.Run(kind, func(t *testing.T) {
			input := newTorHistoryParityFixture(t)
			path := filepath.Join(input.Mount, "state")
			if kind == "final-grep-error" {
				input.write(t, "sudo.grep-error", "")
			} else {
				if err := os.Remove(path); err != nil {
					t.Fatal(err)
				}
				switch kind {
				case "directory":
					if err := os.Mkdir(path, 0o700); err != nil {
						t.Fatal(err)
					}
				case "symlink", "dangling":
					target := "missing"
					if kind == "symlink" {
						target = "real-state"
						input.write(t, "tor/real-state", "CircuitBuildAbandonedCount 1000\nTotalBuildTimes 1000\n")
					}
					if err := os.Symlink(target, path); err != nil {
						t.Fatal(err)
					}
				}
			}
			compareTorHistory(t, input, "saturated")
		})
	}
}

func TestTorHistoryEgressParity(t *testing.T) {
	for _, test := range []struct{ name, first, second, prefix string }{
		{"both-down", "1", "1", ""},
		{"first-up", "0", "1", ""},
		{"second-up", "1", "0", ""},
		{"mixed-errors", "7", "28", "10.20.3\n\n"},
		{"whitespace-prefix", "1", "1", " test prefix "},
	} {
		t.Run(test.name, func(t *testing.T) {
			input := newTorHistoryParityFixture(t)
			input.Prefix = test.prefix
			input.write(t, "curl.first", test.first)
			input.write(t, "curl.second", test.second)
			compareTorHistory(t, input, "egress")
		})
	}
	t.Run("no-curl", func(t *testing.T) {
		input := newTorHistoryParityFixture(t)
		if err := os.Remove(filepath.Join(input.dir, "curl")); err != nil {
			t.Fatal(err)
		}
		compareTorHistory(t, input, "egress")
	})
}

func TestTorHistoryDoctorParity(t *testing.T) {
	for _, name := range []string{"root", "sudo", "refused", "stopped", "no-mount", "not-saturated", "egress-up", "appliance", "mount-newline"} {
		t.Run(name, func(t *testing.T) {
			input := newTorHistoryParityFixture(t)
			switch name {
			case "sudo":
				input.write(t, "id.value", "1000\n")
			case "refused":
				input.write(t, "id.value", "1000\n")
				input.write(t, "sudo.code", "1")
			case "stopped":
				input.write(t, "docker.value", "")
			case "no-mount":
				input.MountAvailable = false
			case "not-saturated":
				input.write(t, "tor/state", "")
			case "egress-up":
				input.write(t, "curl.first", "0")
			case "appliance":
				input.Appliance = true
			case "mount-newline":
				input.Mount += "\n\n"
			}
			compareTorHistory(t, input, "doctor")
		})
	}
}
