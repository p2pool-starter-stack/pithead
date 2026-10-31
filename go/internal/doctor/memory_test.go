package doctor

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestDecisionPages(t *testing.T) {
	tests := []struct {
		name     string
		marker   string
		expected string
	}{
		{"missing", "", "3072"},
		{"first valid", "note\npages=02560\npages=0\n", "02560"},
		{"released", "pages=0\n", "0"},
		{"full", "pages=3072\n", "3072"},
		{"larger", "pages=4096\n", "3072"},
		{"invalid then valid", "pages=-1\npages=2560 \npages=1296\n", "1296"},
		{"carriage return is invalid", "pages=2560\r\npages=1296\n", "1296"},
		{"long line", strings.Repeat("x", 70*1024) + "\npages=1296\n", "1296"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			path := filepath.Join(t.TempDir(), "marker")
			if test.marker != "" {
				if err := os.WriteFile(path, []byte(test.marker), 0o600); err != nil {
					t.Fatal(err)
				}
			}
			if actual := DecisionPages(path); actual != test.expected {
				t.Fatalf("DecisionPages() = %q, want %q", actual, test.expected)
			}
		})
	}
}

func TestMemoryReserved(t *testing.T) {
	tests := []struct {
		name      string
		total     string
		free      string
		marker    string
		appliance bool
		status    string
		contains  []string
	}{
		{"bench pool", "186", "186", "", false, "warn", []string{"only 186 of the 3072 pages", "5772 MiB short", "too few for P2Pool's RandomX dataset", "Run './pithead setup'"}},
		{"full budget", "3072", "1800", "", false, "ok", []string{"3072 total, 1800 free"}},
		{"dataset short", "1039", "1039", "", false, "warn", []string{"too few for P2Pool's RandomX dataset"}},
		{"dataset boundary", "1040", "1040", "", false, "warn", []string{"4064 MiB short", "If monerod's own RandomX pages leave fewer than 1040 free"}},
		{"p2pool boundary", "1296", "1296", "", false, "warn", []string{"3552 MiB short", "this machine needs for RandomX"}},
		{"one short", "3071", "3071", "", false, "warn", []string{"2 MiB short"}},
		{"reduced full", "2560", "2560", "reduced\npages=2560\n", true, "ok", []string{"2560 total"}},
		{"reduced short", "1000", "1000", "reduced\npages=2560\n", true, "warn", []string{"only 1000 of the 2560 pages", "There is no dashboard control"}},
		{"released short", "186", "186", "released\npages=0\n", true, "warn", []string{"only 186 of the 1296 pages", "P2Pool's RandomX dataset and its two caches need", "2220 MiB short"}},
		{"released enough", "1296", "1296", "released\npages=0\n", true, "ok", []string{"1296 total"}},
		{"zero", "0", "0", "", false, "warn", []string{"HugePages_Total is 0", "up to 2592 MiB", "accept setup's GRUB drop-in"}},
		{"leading zero text", "03072", "01800", "", false, "ok", []string{"03072 total, 01800 free"}},
		{"leading zero arithmetic", "01000", "01000", "reduced\npages=02560\n", true, "warn", []string{"only 01000 of the 02560 pages", "1760 MiB short"}},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			dir := t.TempDir()
			meminfo := filepath.Join(dir, "meminfo")
			contents := "MemTotal: 16318412 kB\nHugePages_Total: " + test.total + "\nHugePages_Free: " + test.free + "\n"
			if err := os.WriteFile(meminfo, []byte(contents), 0o600); err != nil {
				t.Fatal(err)
			}
			marker := filepath.Join(dir, "marker")
			if test.marker != "" {
				if err := os.WriteFile(marker, []byte(test.marker), 0o600); err != nil {
					t.Fatal(err)
				}
			}
			finding, err := (Memory{Meminfo: meminfo, Marker: marker, Appliance: test.appliance}).Reserved()
			if err != nil {
				t.Fatal(err)
			}
			if finding.ID != "hugepages" || finding.Status != test.status {
				t.Fatalf("finding = %#v", finding)
			}
			for _, expected := range test.contains {
				if !strings.Contains(finding.Message, expected) {
					t.Errorf("message %q does not contain %q", finding.Message, expected)
				}
			}
		})
	}
}

func TestMemoryReservedUnreadableValues(t *testing.T) {
	for _, contents := range []string{"MemTotal: 1 kB\n", "HugePages_Total: n/a\n", "HugePages_Total: 3072\r\n", "HugePages_Total:\v3072\n", "HugePages_Total:\u00a03072\n", "HugePages_Total: 1\nHugePages_Total: 2\n"} {
		path := filepath.Join(t.TempDir(), "meminfo")
		if err := os.WriteFile(path, []byte(contents), 0o600); err != nil {
			t.Fatal(err)
		}
		finding, err := (Memory{Meminfo: path, Marker: filepath.Join(t.TempDir(), "marker")}).Reserved()
		if err != nil {
			t.Fatal(err)
		}
		if finding.Status != "warn" || finding.Message != "Could not read HugePages from "+path+"." {
			t.Fatalf("finding = %#v", finding)
		}
	}
}

func TestMemoryReservedTrimsTrailingCommandSubstitutionNewlines(t *testing.T) {
	path := filepath.Join(t.TempDir(), "meminfo")
	contents := "HugePages_Total: 3072\nHugePages_Total:\nHugePages_Free: 1800\nHugePages_Free:\n"
	if err := os.WriteFile(path, []byte(contents), 0o600); err != nil {
		t.Fatal(err)
	}
	finding, err := (Memory{Meminfo: path, Marker: filepath.Join(t.TempDir(), "marker")}).Reserved()
	if err != nil {
		t.Fatal(err)
	}
	if finding != (Finding{"hugepages", "ok", "HugePages reserved: 3072 total, 1800 free (RandomX uses these)."}) {
		t.Fatalf("finding = %#v", finding)
	}
}

func TestMemoryReservedUnsupportedInput(t *testing.T) {
	tests := []struct {
		meminfo string
		marker  string
	}{
		{"HugePages_Total: 9223372036854775808\n", ""},
		{"HugePages_Total: 1000\n", "pages=9223372036854775808\n"},
		{"HugePages_Total: 01000\n", "pages=01800\n"},
	}
	for _, test := range tests {
		dir := t.TempDir()
		meminfo := filepath.Join(dir, "meminfo")
		marker := filepath.Join(dir, "marker")
		if err := os.WriteFile(meminfo, []byte(test.meminfo), 0o600); err != nil {
			t.Fatal(err)
		}
		if test.marker != "" {
			if err := os.WriteFile(marker, []byte(test.marker), 0o600); err != nil {
				t.Fatal(err)
			}
		}
		finding, err := (Memory{Meminfo: meminfo, Marker: marker}).Reserved()
		if finding != (Finding{}) || !errors.Is(err, ErrUnsupportedProbeInput) {
			t.Fatalf("Reserved() = (%#v, %v)", finding, err)
		}
	}
}

func TestMemoryDegraded(t *testing.T) {
	dir := t.TempDir()
	marker := filepath.Join(dir, "marker")
	memory := Memory{Marker: marker}
	if findings, err := memory.Degraded(); err != nil || len(findings) != 0 {
		t.Fatalf("missing marker findings = %#v", findings)
	}
	if err := os.WriteFile(marker, []byte("Reduced\treservation\npages=2560\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	findings, err := memory.Degraded()
	if err != nil {
		t.Fatal(err)
	}
	if len(findings) != 1 || findings[0] != (Finding{"hugepages-degraded", "warn", "Reduced reservation"}) {
		t.Fatalf("findings = %#v", findings)
	}
	if err := os.WriteFile(marker, []byte("Reduced\r\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if findings, err = memory.Degraded(); err != nil || len(findings) != 1 || findings[0].Message != "Reduced\r" {
		t.Fatalf("carriage return marker findings = %#v", findings)
	}
	if err := os.WriteFile(marker, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	if findings, err = memory.Degraded(); err != nil || len(findings) != 1 || findings[0].Message != "" {
		t.Fatalf("empty marker findings = %#v", findings)
	}
}

func TestMemoryRejectsNULSubstitutionValues(t *testing.T) {
	tests := []struct {
		name     string
		contents string
		probe    func(Memory) error
	}{
		{"hugepages total", "HugePages_Total: 30\x0072\n", func(memory Memory) error { _, err := memory.Reserved(); return err }},
		{"hugepages free", "HugePages_Total: 3072\nHugePages_Free: 18\x0000\n", func(memory Memory) error { _, err := memory.Reserved(); return err }},
		{"available", "MemAvailable: 2097\x00152\n", func(memory Memory) error { _, err := memory.Available(); return err }},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			path := filepath.Join(t.TempDir(), "meminfo")
			if err := os.WriteFile(path, []byte(test.contents), 0o600); err != nil {
				t.Fatal(err)
			}
			if err := test.probe(Memory{Meminfo: path, Marker: filepath.Join(t.TempDir(), "marker")}); !errors.Is(err, ErrUnsupportedProbeInput) {
				t.Fatalf("error = %v", err)
			}
		})
	}

	marker := filepath.Join(t.TempDir(), "marker")
	if err := os.WriteFile(marker, []byte("Reduced\x00 reservation\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	findings, err := (Memory{Marker: marker}).Degraded()
	if findings != nil || !errors.Is(err, ErrUnsupportedProbeInput) {
		t.Fatalf("Degraded() = (%#v, %v)", findings, err)
	}
}

func TestMemoryAvailable(t *testing.T) {
	tests := []struct {
		contents string
		status   string
		message  string
	}{
		{"MemAvailable: 2097152 kB\n", "ok", "Free RAM: 2048 MiB available."},
		{"MemAvailable: 2097151 kB\n", "warn", "Free RAM low: 2047 MiB available — the stack (Tari especially) may be memory-starved."},
		{"MemAvailable: -2097152 kB\n", "warn", "Free RAM low: -2048 MiB available — the stack (Tari especially) may be memory-starved."},
		{"MemAvailable: -0102400 kB\n", "warn", "Free RAM low: -33 MiB available — the stack (Tari especially) may be memory-starved."},
		{"MemAvailable: +0102400 kB\n", "warn", "Free RAM low: 33 MiB available — the stack (Tari especially) may be memory-starved."},
		{"MemTotal: 4194304 kB\n", "warn", "Could not read MemAvailable from /proc/meminfo."},
	}
	for _, test := range tests {
		path := filepath.Join(t.TempDir(), "meminfo")
		if err := os.WriteFile(path, []byte(test.contents), 0o600); err != nil {
			t.Fatal(err)
		}
		finding, err := (Memory{Meminfo: path}).Available()
		if err != nil {
			t.Fatal(err)
		}
		if finding != (Finding{"free-ram", test.status, test.message}) {
			t.Fatalf("finding = %#v", finding)
		}
	}
}

func TestMemoryAvailableUnsupportedInput(t *testing.T) {
	for _, value := range []string{"not-a-number", "02097152", "9223372036854775808"} {
		path := filepath.Join(t.TempDir(), "meminfo")
		if err := os.WriteFile(path, []byte("MemAvailable: "+value+" kB\n"), 0o600); err != nil {
			t.Fatal(err)
		}
		finding, err := (Memory{Meminfo: path}).Available()
		if finding != (Finding{}) || !errors.Is(err, ErrUnsupportedProbeInput) {
			t.Fatalf("Available(%q) = (%#v, %v)", value, finding, err)
		}
	}
}
