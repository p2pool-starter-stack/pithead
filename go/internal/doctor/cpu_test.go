package doctor

import (
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func TestCPUHasAVX2(t *testing.T) {
	for _, tc := range []struct {
		name, platform, data, code string
		want                       bool
	}{
		{"linux present", "Linux", "flags: avx2 sse\n", "0", true},
		{"linux substring", "Linux", "flags: no-avx2-here\n", "0", true},
		{"linux case", "Linux", "flags: AVX2\n", "0", false},
		{"linux empty", "Linux", "", "0", false},
		{"darwin present", "Darwin", "machdep.cpu.features: AVX2\n", "0", true},
		{"darwin wrong line", "Darwin", "other.features: AVX2\n", "0", false},
		{"darwin case", "Darwin", "machdep.cpu.features: avx2\n", "0", false},
		{"darwin regex", "Darwin", "machdepXcpu.features: AVX2\n", "0", true},
		{"darwin upstream error", "Darwin", "machdep.cpu.features: AVX2\n", "7", false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			cpu, _ := fakeCPUProbe(t, tc.platform, tc.data, tc.code)
			got, err := cpu.HasAVX2()
			if err != nil || got != tc.want {
				t.Fatalf("HasAVX2 = %t, %v; want %t", got, err, tc.want)
			}
			finding, err := cpu.Finding()
			if err != nil || finding.ID != "cpu-avx2" || (finding.Status == "ok") != tc.want {
				t.Fatalf("CPU finding = %+v, %v", finding, err)
			}
		})
	}
}

func TestDarwinAVX2PipelineFailure(t *testing.T) {
	data := "machdep.cpu.features: AVX2\n" + strings.Repeat("machdep.cpu.other: filler\n", 100000)
	cpu, _ := fakeCPUProbe(t, "Darwin", data, "0")
	if got, err := cpu.HasAVX2(); err != nil || got {
		t.Fatalf("upstream SIGPIPE must fail the pipeline: %t, %v", got, err)
	}
}

func TestCPUProbeMissingInputs(t *testing.T) {
	cpu, dir := fakeCPUProbe(t, "Linux", "flags: avx2\n", "0")
	cpu.CPUInfo = filepath.Join(dir, "missing")
	if got, err := cpu.HasAVX2(); err != nil || got {
		t.Fatalf("missing cpuinfo = %t, %v", got, err)
	}
	if err := os.Remove(filepath.Join(dir, "sysctl")); err != nil {
		t.Fatal(err)
	}
	if got, err := (CPU{OS: "Darwin"}).HasAVX2(); err != nil || got {
		t.Fatalf("missing sysctl = %t, %v", got, err)
	}
	if err := os.Remove(filepath.Join(dir, "grep")); err != nil {
		t.Fatal(err)
	}
	if got, err := (CPU{OS: "Darwin"}).HasAVX2(); !errors.Is(err, ErrUnsupportedProbeInput) || got {
		t.Fatalf("missing Darwin grep must retain Bash diagnostics: %t, %v", got, err)
	}
}

func fakeCPUProbe(t *testing.T, platform, data, code string) (CPU, string) {
	t.Helper()
	grep, err := exec.LookPath("grep")
	if err != nil {
		t.Fatal(err)
	}
	cat, err := exec.LookPath("cat")
	if err != nil {
		t.Fatal(err)
	}
	dir := t.TempDir()
	if err := os.Symlink(grep, filepath.Join(dir, "grep")); err != nil {
		t.Fatal(err)
	}
	input := filepath.Join(dir, "cpuinfo")
	if err := os.WriteFile(input, []byte(data), 0o600); err != nil {
		t.Fatal(err)
	}
	stub := "#!/bin/sh\n\"$CPU_CAT\" \"$CPU_OUTPUT\"\nexit \"$CPU_CODE\"\n"
	if err := os.WriteFile(filepath.Join(dir, "sysctl"), []byte(stub), 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("CPU_CAT", cat)
	t.Setenv("CPU_OUTPUT", input)
	t.Setenv("CPU_CODE", code)
	t.Setenv("PATH", dir)
	return CPU{OS: platform, CPUInfo: input}, dir
}
