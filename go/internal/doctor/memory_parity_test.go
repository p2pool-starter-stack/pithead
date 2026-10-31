//go:build parity

package doctor

import (
	"bytes"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func TestMemoryReservedParity(t *testing.T) {
	tests := []struct {
		name      string
		total     string
		free      string
		marker    string
		appliance bool
	}{
		{"zero DIY", "0", "0", "", false},
		{"bench pool", "186", "186", "", false},
		{"dataset short", "1039", "1039", "", false},
		{"dataset boundary", "1040", "1040", "", false},
		{"released one short", "1295", "1295", "released\npages=0\n", true},
		{"released boundary", "1296", "1296", "released\npages=0\n", true},
		{"reduced boundary", "2560", "2560", "reduced\npages=2560\n", true},
		{"full one short", "3071", "3071", "", false},
		{"full boundary", "3072", "1800", "", false},
		{"leading zero arithmetic", "01000", "01000", "reduced\npages=02560\n", true},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			meminfo := "MemTotal: 16318412 kB\nHugePages_Total: " + test.total + "\nHugePages_Free: " + test.free + "\n"
			fixture := bashMemory(t, "reserved", &meminfo, optional(test.marker), test.appliance)
			finding, err := (Memory{Meminfo: fixture.meminfo, Marker: fixture.marker, Appliance: test.appliance}).Reserved()
			if err != nil {
				t.Fatal(err)
			}
			assertMemoryFinding(t, fixture, []Finding{finding})
		})
	}
}

func TestMemoryReservedUnreadableParity(t *testing.T) {
	tests := []struct {
		name    string
		meminfo *string
	}{
		{"missing file", nil},
		{"missing field", stringPointer("MemTotal: 4194304 kB\n")},
		{"invalid field", stringPointer("HugePages_Total: n/a\n")},
		{"duplicate field", stringPointer("HugePages_Total: 1\nHugePages_Total: 2\n")},
		{"trailing empty fields", stringPointer("HugePages_Total: 3072\nHugePages_Total:\nHugePages_Free: 1800\nHugePages_Free:\n")},
		{"missing free", stringPointer("HugePages_Total: 3072\n")},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			fixture := bashMemory(t, "reserved", test.meminfo, nil, false)
			finding, err := (Memory{Meminfo: fixture.meminfo, Marker: fixture.marker}).Reserved()
			if err != nil {
				t.Fatal(err)
			}
			assertMemoryFinding(t, fixture, []Finding{finding})
		})
	}
}

func TestDecisionPagesParity(t *testing.T) {
	tests := []struct {
		name   string
		marker *string
	}{
		{"missing", nil},
		{"empty", stringPointer("")},
		{"released", stringPointer("released\npages=0\n")},
		{"reduced", stringPointer("reduced\npages=2560\n")},
		{"first valid", stringPointer("pages=-1\npages=2560 \npages=1296\npages=0\n")},
		{"leading zeros", stringPointer("pages=02560\n")},
		{"full", stringPointer("pages=3072\n")},
		{"larger", stringPointer("pages=4096\n")},
		{"carriage return", stringPointer("pages=2560\r\n")},
		{"tab suffix", stringPointer("pages=2560\t\n")},
		{"tab prefix", stringPointer("\tpages=2560\n")},
		{"embedded tab", stringPointer("pages=25\t60\n")},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			fixture := bashMemory(t, "decision", nil, test.marker, false)
			want := strings.TrimSuffix(fixture.stdout, "\n")
			if got := DecisionPages(fixture.marker); got != want {
				t.Fatalf("DecisionPages() = %q, want %q", got, want)
			}
			if fixture.stderr != "" || fixture.code != 0 {
				t.Fatalf("Bash stderr = %q, exit = %d", fixture.stderr, fixture.code)
			}
		})
	}
}

func TestMemoryDegradedParity(t *testing.T) {
	tests := []struct {
		name   string
		marker *string
	}{
		{"missing", nil},
		{"empty", stringPointer("")},
		{"words", stringPointer("Reduced reservation\npages=2560\n")},
		{"tabs", stringPointer("Reduced\treservation\tfor host\npages=2560\n")},
		{"blank first line", stringPointer("\npages=2560\n")},
		{"carriage return", stringPointer("Reduced reservation\r\npages=2560\n")},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			fixture := bashMemory(t, "degraded", nil, test.marker, true)
			findings, err := (Memory{Marker: fixture.marker, Appliance: true}).Degraded()
			if err != nil {
				t.Fatal(err)
			}
			assertMemoryFinding(t, fixture, findings)
		})
	}
}

func TestMemoryAvailableParity(t *testing.T) {
	tests := []struct {
		name    string
		content *string
	}{
		{"missing file", nil},
		{"missing field", stringPointer("MemTotal: 4194304 kB\n")},
		{"zero", stringPointer("MemAvailable: 0 kB\n")},
		{"one below", stringPointer("MemAvailable: 2097151 kB\n")},
		{"boundary", stringPointer("MemAvailable: 2097152 kB\n")},
		{"fraction discarded", stringPointer("MemAvailable: 2098175 kB\n")},
		{"leading zero arithmetic", stringPointer("MemAvailable: 02000000 kB\n")},
		{"positive signed octal", stringPointer("MemAvailable: +0102400 kB\n")},
		{"negative signed octal", stringPointer("MemAvailable: -0102400 kB\n")},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			fixture := bashMemory(t, "available", test.content, nil, false)
			finding, err := (Memory{Meminfo: fixture.meminfo}).Available()
			if err != nil {
				t.Fatal(err)
			}
			assertMemoryFinding(t, fixture, []Finding{finding})
			switch test.name {
			case "positive signed octal":
				if finding.Message != "Free RAM low: 33 MiB available — the stack (Tari especially) may be memory-starved." {
					t.Fatalf("finding = %#v", finding)
				}
			case "negative signed octal":
				if finding.Message != "Free RAM low: -33 MiB available — the stack (Tari especially) may be memory-starved." {
					t.Fatalf("finding = %#v", finding)
				}
			}
		})
	}
}

func TestMemoryAvailableInvalidBashParity(t *testing.T) {
	for _, content := range []string{"MemAvailable: n/a kB\n", "MemAvailable: 08 kB\n", "MemAvailable: -0102800 kB\n", "MemAvailable: 1 kB\nMemAvailable: 2 kB\n"} {
		fixture := bashMemory(t, "available", &content, nil, false)
		finding, err := (Memory{Meminfo: fixture.meminfo}).Available()
		if !errors.Is(err, ErrUnsupportedProbeInput) || finding != (Finding{}) {
			t.Fatalf("Go result = %#v, %v", finding, err)
		}
		if fixture.code == 0 || fixture.stdout != "" || fixture.stderr == "" {
			t.Fatalf("Bash result = exit %d, stdout %q, stderr %q", fixture.code, fixture.stdout, fixture.stderr)
		}
	}
}

func TestMemoryReservedUnsupportedBashParity(t *testing.T) {
	tests := []struct {
		meminfo string
		marker  *string
	}{
		{"HugePages_Total: 08\nHugePages_Free: 08\n", nil},
		{"HugePages_Total: 3072\nHugePages_Free: 1\n", stringPointer("pages=999999999999999999999999\n")},
		{"HugePages_Total: 999999999999999999999999\nHugePages_Free: 1\n", nil},
		{"HugePages_Total: 3072\x00\nHugePages_Free: 1\n", nil},
	}
	for _, test := range tests {
		fixture := bashMemory(t, "reserved", &test.meminfo, test.marker, false)
		finding, err := (Memory{Meminfo: fixture.meminfo, Marker: fixture.marker}).Reserved()
		if !errors.Is(err, ErrUnsupportedProbeInput) || finding != (Finding{}) {
			t.Fatalf("Go result = %#v, %v", finding, err)
		}
		if fixture.stderr == "" {
			t.Fatalf("Bash result = exit %d, stdout %q, stderr %q", fixture.code, fixture.stdout, fixture.stderr)
		}
	}
}

func TestMemoryDegradedUnsupportedBashParity(t *testing.T) {
	marker := "Reduced\x00 reservation\npages=2560\n"
	fixture := bashMemory(t, "degraded", nil, &marker, true)
	findings, err := (Memory{Marker: fixture.marker, Appliance: true}).Degraded()
	if !errors.Is(err, ErrUnsupportedProbeInput) || findings != nil {
		t.Fatalf("Go result = %#v, %v", findings, err)
	}
	if fixture.stderr == "" {
		t.Fatalf("Bash result = exit %d, stdout %q, stderr %q", fixture.code, fixture.stdout, fixture.stderr)
	}
}

type memoryFixture struct {
	meminfo string
	marker  string
	stdout  string
	stderr  string
	code    int
}

func bashMemory(t *testing.T, operation string, meminfo, marker *string, appliance bool) memoryFixture {
	t.Helper()
	dir := t.TempDir()
	meminfoPath := filepath.Join(dir, "meminfo")
	markerPath := filepath.Join(dir, "marker")
	if meminfo != nil {
		if err := os.WriteFile(meminfoPath, []byte(*meminfo), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	if marker != nil {
		if err := os.WriteFile(markerPath, []byte(*marker), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	root, err := filepath.Abs(filepath.Join("..", "..", ".."))
	if err != nil {
		t.Fatal(err)
	}
	script := filepath.Join(root, "tests", "go-parity", "doctor_memory_reference.sh")
	path, err := exec.LookPath("bash")
	if err != nil {
		t.Fatal(err)
	}
	applianceValue := "0"
	if appliance {
		applianceValue = "1"
	}
	command := exec.Command(path, script, root, operation, meminfoPath, markerPath, applianceValue)
	command.Env = []string{
		"PATH=" + os.Getenv("PATH"),
		"TMPDIR=" + dir,
		"CLOCK_ARGS=" + os.Getenv("CLOCK_ARGS"),
		"CLOCK_OUTPUT=" + os.Getenv("CLOCK_OUTPUT"),
		"CLOCK_EXIT=" + os.Getenv("CLOCK_EXIT"),
	}
	var stdout, stderr bytes.Buffer
	command.Stdout, command.Stderr = &stdout, &stderr
	err = command.Run()
	code := 0
	if err != nil {
		var exit *exec.ExitError
		if !errors.As(err, &exit) {
			t.Fatal(err)
		}
		code = exit.ExitCode()
	}
	return memoryFixture{meminfoPath, markerPath, stdout.String(), stderr.String(), code}
}

func assertMemoryFinding(t *testing.T, fixture memoryFixture, findings []Finding) {
	t.Helper()
	var rows, human strings.Builder
	for _, finding := range findings {
		rows.WriteString(finding.Status + "\t" + finding.Message + "\t" + finding.ID + "\n")
		switch finding.Status {
		case "ok":
			human.WriteString("  ✓ OK   " + finding.Message + "\n")
		case "warn":
			human.WriteString("  ⚠ WARN " + finding.Message + "\n")
		case "info":
			human.WriteString("  •      " + finding.Message + "\n")
		}
	}
	if fixture.code != 0 || fixture.stdout != rows.String() || fixture.stderr != human.String() {
		t.Fatalf("Bash = exit %d, rows %q, human %q; Go rows %q, human %q", fixture.code, fixture.stdout, fixture.stderr, rows.String(), human.String())
	}
}

func stringPointer(value string) *string { return &value }

func optional(value string) *string {
	if value == "" {
		return nil
	}
	return &value
}
