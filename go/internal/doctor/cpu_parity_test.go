//go:build parity

package doctor

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestHostCPULinuxParity(t *testing.T) {
	tests := []struct {
		name    string
		content *string
	}{
		{"present", stringPointer("flags : sse avx avx2 bmi\n")},
		{"absent", stringPointer("flags : sse avx bmi\n")},
		{"case sensitive", stringPointer("flags : AVX2\n")},
		{"substring", stringPointer("flags : notavx2ish\n")},
		{"missing", nil},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			dir := t.TempDir()
			cpuinfo := filepath.Join(dir, "cpuinfo")
			if test.content != nil {
				if err := os.WriteFile(cpuinfo, []byte(*test.content), 0o600); err != nil {
					t.Fatal(err)
				}
			}
			writeHostTool(t, dir, "grep", "exec /usr/bin/grep \"$@\"\n")
			t.Setenv("PATH", dir)
			result := runHostBash(t, "cpu-has-avx2", false, cpuinfo, "Linux")
			got, err := (CPU{OS: "Linux", CPUInfo: cpuinfo}).HasAVX2()
			if err != nil {
				t.Fatal(err)
			}
			if got != (result.code == 0) {
				t.Fatalf("HasAVX2() = %v, Bash exit = %d", got, result.code)
			}
			finding, err := (CPU{OS: "Linux", CPUInfo: cpuinfo}).Finding()
			if err != nil {
				t.Fatal(err)
			}
			assertHostFindings(t, runHostBash(t, "cpu", false, cpuinfo, "Linux"), []Finding{finding})
		})
	}
}

func TestHostCPUDarwinParity(t *testing.T) {
	large := strings.Repeat("machdep.cpu.features: SSE AVX2\n", 20000)
	tests := []struct {
		name   string
		output string
		code   string
	}{
		{"present", "machdep.cpu.features: SSE AVX2\n", "0"},
		{"absent", "machdep.cpu.features: SSE AVX\n", "0"},
		{"irrelevant", "other.feature: AVX2\n", "0"},
		{"failure with match", "machdep.cpu.features: AVX2\n", "7"},
		{"large pipe", large, "0"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			dir := t.TempDir()
			writeHostTool(t, dir, "grep", "exec /usr/bin/grep \"$@\"\n")
			writeHostTool(t, dir, "sysctl", "printf '%s' \"$SYSCTL_OUTPUT\"\nexit \"$SYSCTL_EXIT\"\n")
			t.Setenv("PATH", dir)
			t.Setenv("SYSCTL_OUTPUT", test.output)
			t.Setenv("SYSCTL_EXIT", test.code)
			cpu := CPU{OS: "Darwin"}
			result := runHostBash(t, "cpu-has-avx2", false, filepath.Join(dir, "unused"), "Darwin")
			got, err := cpu.HasAVX2()
			if err != nil {
				t.Fatal(err)
			}
			if got != (result.code == 0) {
				t.Fatalf("HasAVX2() = %v, Bash exit = %d", got, result.code)
			}
			finding, err := cpu.Finding()
			if err != nil {
				t.Fatal(err)
			}
			assertHostFindings(t, runHostBash(t, "cpu", false, filepath.Join(dir, "unused"), "Darwin"), []Finding{finding})
		})
	}
}
