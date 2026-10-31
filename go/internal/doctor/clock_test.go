package doctor

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestClockSyncStatus(t *testing.T) {
	for _, tc := range []struct {
		name, output, exit, want string
	}{
		{"yes", "yes\n\n", "0", "synced"},
		{"no", "no\n", "0", "unsynced"},
		{"blank", "", "0", "unknown"},
		{"whitespace", "yes \n", "0", "unknown"},
		{"uppercase", "YES\n", "0", "unknown"},
		{"failure with output", "yes\n", "7", "synced"},
		{"failure without output", "", "7", "unknown"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			args := fakeClock(t, tc.output, tc.exit)
			if got, err := ClockSyncStatus(); err != nil || got != tc.want {
				t.Fatalf("ClockSyncStatus = %q, %v; want %q", got, err, tc.want)
			}
			data, err := os.ReadFile(args)
			if err != nil || string(data) != "show -p NTPSynchronized --value\n" {
				t.Fatalf("timedatectl arguments = %q, error %v", data, err)
			}
		})
	}
}

func TestClockSyncMissingTool(t *testing.T) {
	t.Setenv("PATH", t.TempDir())
	if got, err := ClockSyncStatus(); err != nil || got != "unknown" {
		t.Fatalf("missing tool returned %q, %v", got, err)
	}
}

func TestClockSyncFinding(t *testing.T) {
	for _, appliance := range []bool{false, true} {
		for _, output := range []string{"yes", "no", ""} {
			t.Run(fmt.Sprintf("%t/%q", appliance, output), func(t *testing.T) {
				fakeClock(t, output, "0")
				got, err := ClockSync(appliance)
				if err != nil {
					t.Fatal(err)
				}
				if got.ID != "clock-sync" {
					t.Fatalf("clock check lost its id: %+v", got)
				}
				switch output {
				case "yes":
					if got.Status != "ok" || got.Message != "System clock is NTP-synchronized." {
						t.Fatalf("synchronized check = %+v", got)
					}
				case "no":
					if got.Status != "warn" || !strings.Contains(got.Message, "NOT NTP-synchronized") || strings.Contains(got.Message, "dashboard control") != appliance {
						t.Fatalf("unsynchronized check = %+v", got)
					}
				default:
					if got.Status != "info" || !strings.Contains(got.Message, "Could not verify") {
						t.Fatalf("unknown clock = %+v", got)
					}
				}
			})
		}
	}
}

func TestClockSyncNULRequiresFallback(t *testing.T) {
	fakeClock(t, "yes", "0")
	tool := filepath.Join(strings.Split(os.Getenv("PATH"), string(os.PathListSeparator))[0], "timedatectl")
	if err := os.WriteFile(tool, []byte("#!/bin/sh\nprintf 'yes\\000\\n'\n"), 0o700); err != nil {
		t.Fatal(err)
	}
	if got, err := ClockSyncStatus(); !errors.Is(err, ErrUnsupportedProbeInput) || got != "" {
		t.Fatalf("NUL status = %q, %v", got, err)
	}
	if got, err := ClockSync(false); !errors.Is(err, ErrUnsupportedProbeInput) || got != (Finding{}) {
		t.Fatalf("NUL finding = %+v, %v", got, err)
	}
}

func fakeClock(t *testing.T, output, code string) string {
	t.Helper()
	dir := t.TempDir()
	args := filepath.Join(dir, "arguments")
	tool := "#!/bin/sh\nprintf '%s\\n' \"$*\" >\"$CLOCK_ARGS\"\nprintf '%s' \"$CLOCK_OUTPUT\"\nexit \"$CLOCK_EXIT\"\n"
	if err := os.WriteFile(filepath.Join(dir, "timedatectl"), []byte(tool), 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))
	t.Setenv("CLOCK_ARGS", args)
	t.Setenv("CLOCK_OUTPUT", output)
	t.Setenv("CLOCK_EXIT", code)
	return args
}
