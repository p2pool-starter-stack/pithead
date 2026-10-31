package doctor

import (
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

var exposureTrPath, _ = exec.LookPath("tr")

func TestStratumExposureFindings(t *testing.T) {
	dir := t.TempDir()
	writeExposureIP(t, dir, "#!/bin/sh\nprintf '%s\\n' '1: eth0 inet 8.8.8.8/24 scope global'")
	t.Setenv("PATH", dir)
	tests := []struct {
		name      string
		input     StratumExposure
		status    string
		message   string
		forbidden string
	}{
		{"open", StratumExposure{}, "warn", "stratum port 3333 is unauthenticated", "8.8.8.8"},
		{"password", StratumExposure{Password: "secret\n"}, "warn", "requires a password but is still cleartext", "secret"},
		{"tls", StratumExposure{TLS: "YES\n"}, "warn", "offers TLS, but rigs not switched to TLS", "8.8.8.8"},
		{"protected", StratumExposure{Password: "secret", TLS: "true"}, "info", "has a password and TLS available", "secret"},
		{"appliance", StratumExposure{Appliance: true}, "warn", "This machine appears to have a public IP", "8.8.8.8"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			findings, err := test.input.Findings()
			if err != nil || len(findings) != 1 || findings[0].Status != test.status || !strings.Contains(findings[0].Message, test.message) || strings.Contains(findings[0].Message, test.forbidden) {
				t.Fatalf("Findings() = %#v, %v", findings, err)
			}
		})
	}
}

func TestStratumExposureBindingAndHostState(t *testing.T) {
	dir := t.TempDir()
	writeExposureIP(t, dir, "#!/bin/sh\nprintf '%s\\n' '1: eth0 inet 8.8.8.8/24 scope global'")
	if err := os.WriteFile(filepath.Join(dir, "grep"), []byte("#!/bin/sh\nexit 0"), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", dir)
	for _, test := range []struct {
		bind    string
		message string
	}{
		{"127.0.0.1", "bound to 127.0.0.1 (not all interfaces)"},
		{"8.8.8.8", "appears to have a public IP"},
		{"8.8.8.8\n", "appears to have a public IP"},
	} {
		findings, err := (StratumExposure{Stratum: Stratum{Bind: test.bind, Port: "4444"}}).Findings()
		if err != nil || len(findings) != 1 || !strings.Contains(findings[0].Message, test.message) || !strings.Contains(findings[0].Message, "4444") {
			t.Fatalf("Findings(%q) = %#v, %v", test.bind, findings, err)
		}
	}
	writeExposureIP(t, dir, "#!/bin/sh\nprintf '%s\\n' '1: eth0 inet 10.0.0.2/24 scope global'")
	findings, err := (StratumExposure{}).Findings()
	if err != nil || len(findings) != 1 || findings[0].Status != "ok" || !strings.Contains(findings[0].Message, "No public IP") {
		t.Fatalf("Findings() = %#v, %v", findings, err)
	}
}

func TestStratumExposureMissingAndUnsupportedIP(t *testing.T) {
	t.Setenv("PATH", t.TempDir())
	findings, err := (StratumExposure{}).Findings()
	if err != nil || len(findings) != 1 || findings[0].Status != "info" || !strings.Contains(findings[0].Message, "no 'ip' command") {
		t.Fatalf("Findings() = %#v, %v", findings, err)
	}
	if warnings, err := (StratumExposure{}).Warnings(); err != nil || warnings != nil {
		t.Fatalf("Warnings() = %#v, %v", warnings, err)
	}
	dir := t.TempDir()
	writeExposureIP(t, dir, "exit 0")
	t.Setenv("PATH", dir)
	if findings, err := (StratumExposure{}).Findings(); findings != nil || !errors.Is(err, ErrUnsupportedProbeInput) {
		t.Fatalf("Findings() = %#v, %v", findings, err)
	}
}

func TestStratumExposureWarnings(t *testing.T) {
	dir := t.TempDir()
	writeExposureIP(t, dir, "#!/bin/sh\nprintf '%s\\n' '1: eth0 inet 8.8.8.8/24 scope global' '2: eth0 inet6 2001:db8::1/64 scope global'")
	t.Setenv("PATH", dir)
	warnings, err := (StratumExposure{Stratum: Stratum{Port: "4444"}}).Warnings()
	if err != nil || len(warnings) != 1 || !strings.Contains(warnings[0], "8.8.8.8, 2001:db8::1") || !strings.Contains(warnings[0], "port 4444") {
		t.Fatalf("Warnings() = %#v, %v", warnings, err)
	}
	if warnings, err := (StratumExposure{Stratum: Stratum{Port: `33\\33`}}).Warnings(); warnings != nil || !errors.Is(err, ErrUnsupportedProbeInput) {
		t.Fatalf("Warnings() = %#v, %v", warnings, err)
	}
}

func TestStratumExposureNarrowedFallbacks(t *testing.T) {
	dir := t.TempDir()
	writeExposureIP(t, dir, "#!/bin/sh\nprintf '%s\\n' '1: eth0 inet 8.8.8.8/24 scope global'")
	t.Setenv("PATH", dir)
	for _, bind := range []string{"127.0.0.1", "-q"} {
		if findings, err := (StratumExposure{Stratum: Stratum{Bind: bind}}).Findings(); findings != nil || !errors.Is(err, ErrUnsupportedProbeInput) {
			t.Fatalf("Findings(%q) = %#v, %v", bind, findings, err)
		}
	}
	findings, err := (StratumExposure{}).Findings()
	if err != nil || len(findings) != 1 || findings[0].Status != "warn" {
		t.Fatalf("Findings(wildcard) = %#v, %v", findings, err)
	}
}

func TestStratumExposureTLSFallbacks(t *testing.T) {
	for _, test := range []struct {
		name string
		tool string
	}{
		{"missing", ""},
		{"stderr", "#!/bin/sh\nprintf problem >&2\nprintf true"},
		{"nul", "#!/bin/sh\nprintf 'true\\000'"},
	} {
		t.Run(test.name, func(t *testing.T) {
			dir := t.TempDir()
			writeExposureIP(t, dir, "#!/bin/sh\nprintf '%s\\n' '1: eth0 inet 8.8.8.8/24 scope global'")
			if err := os.Remove(filepath.Join(dir, "tr")); err != nil {
				t.Fatal(err)
			}
			if test.tool != "" {
				if err := os.WriteFile(filepath.Join(dir, "tr"), []byte(test.tool), 0o755); err != nil {
					t.Fatal(err)
				}
			}
			t.Setenv("PATH", dir)
			if findings, err := (StratumExposure{TLS: "true"}).Findings(); findings != nil || !errors.Is(err, ErrUnsupportedProbeInput) {
				t.Fatalf("Findings() = %#v, %v", findings, err)
			}
		})
	}
}

func TestStratumExposureTLSQuietNonzeroOutput(t *testing.T) {
	dir := t.TempDir()
	writeExposureIP(t, dir, "#!/bin/sh\nprintf '%s\\n' '1: eth0 inet 8.8.8.8/24 scope global'")
	if err := os.Remove(filepath.Join(dir, "tr")); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "tr"), []byte("#!/bin/sh\nprintf true\nexit 7"), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", dir)
	findings, err := (StratumExposure{Password: "secret", TLS: "ignored"}).Findings()
	if err != nil || len(findings) != 1 || findings[0].Status != "info" {
		t.Fatalf("Findings() = %#v, %v", findings, err)
	}
}

func writeExposureIP(t *testing.T, dir, body string) {
	t.Helper()
	if exposureTrPath == "" {
		t.Fatal("tr unavailable")
	}
	if err := os.Symlink(exposureTrPath, filepath.Join(dir, "tr")); err != nil && !os.IsExist(err) {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "ip"), []byte(body), 0o755); err != nil {
		t.Fatal(err)
	}
}
