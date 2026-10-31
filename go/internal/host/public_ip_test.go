package host

import (
	"errors"
	"os"
	"path/filepath"
	"testing"
)

func TestPublicIP(t *testing.T) {
	tests := map[string]bool{
		"8.8.8.8":        true,
		"010.0.0.1":      true,
		"169.0254.1.1":   false,
		"10.0.0.1":       false,
		"100.64.0.1":     false,
		"172.031.0.1":    false,
		"192.168.1.1":    false,
		"256.1.1.1":      false,
		"2001:db8::1":    true,
		"3fff:anything":  true,
		"4000::1":        false,
		"fc00::1":        false,
		"::1":            false,
		"not-an-address": false,
		"200g:db8::1":    false,
	}
	for value, want := range tests {
		got, err := PublicIP(value)
		if err != nil || got != want {
			t.Errorf("PublicIP(%q) = %v, %v; want %v, nil", value, got, err, want)
		}
	}
	for _, value := range []string{"8.8.8.8\x00", "10000000000002000::1"} {
		if got, err := PublicIP(value); got || !errors.Is(err, ErrUnsupportedIPInput) {
			t.Errorf("PublicIP(%q) = %v, %v", value, got, err)
		}
	}
}

func TestPublicIPs(t *testing.T) {
	dir := t.TempDir()
	writeIPTool(t, dir, "#!/bin/sh\nprintf '%s' '1: eth0 inet 8.8.8.8/24 scope global\n2: eth0 inet 10.0.0.1/8 scope global\n3: eth0 inet6 2001:db8::1/64 scope global\n4: eth0 inet 8.8.8.8/24 scope global\n5: eth0 inet 9.9.9.9/24'")
	t.Setenv("PATH", dir)
	got, err := PublicIPs()
	if err != nil || got != "8.8.8.8\n2001:db8::1\n8.8.8.8\n" {
		t.Fatalf("PublicIPs() = %q, %v", got, err)
	}
}

func TestPublicIPsAcceptsNonzeroOutput(t *testing.T) {
	dir := t.TempDir()
	writeIPTool(t, dir, "#!/bin/sh\nprintf '%s\\n' '1: eth0 inet 8.8.4.4/24 scope global'\nexit 9")
	t.Setenv("PATH", dir)
	got, err := PublicIPs()
	if err != nil || got != "8.8.4.4\n" {
		t.Fatalf("PublicIPs() = %q, %v", got, err)
	}
}

func TestPublicIPsUnsupportedLaunches(t *testing.T) {
	t.Run("missing", func(t *testing.T) {
		t.Setenv("PATH", t.TempDir())
		if got, err := PublicIPs(); got != "" || err != nil {
			t.Fatalf("PublicIPs() = %q, %v", got, err)
		}
	})
	t.Run("relative", func(t *testing.T) {
		dir := t.TempDir()
		writeIPTool(t, dir, "#!/bin/sh\nexit 0")
		old, err := os.Getwd()
		if err != nil {
			t.Fatal(err)
		}
		if err := os.Chdir(dir); err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { _ = os.Chdir(old) })
		t.Setenv("PATH", ".")
		if got, err := PublicIPs(); got != "" || !errors.Is(err, ErrUnsupportedIPInput) {
			t.Fatalf("PublicIPs() = %q, %v", got, err)
		}
	})
	t.Run("no shebang", func(t *testing.T) {
		dir := t.TempDir()
		writeIPTool(t, dir, "exit 0")
		t.Setenv("PATH", dir)
		if got, err := PublicIPs(); got != "" || !errors.Is(err, ErrUnsupportedIPInput) {
			t.Fatalf("PublicIPs() = %q, %v", got, err)
		}
	})
	t.Run("nul", func(t *testing.T) {
		dir := t.TempDir()
		writeIPTool(t, dir, "#!/bin/sh\nprintf '1: eth0 inet 8.8.8.8/24\\000 scope global\\n'")
		t.Setenv("PATH", dir)
		if got, err := PublicIPs(); got != "" || !errors.Is(err, ErrUnsupportedIPInput) {
			t.Fatalf("PublicIPs() = %q, %v", got, err)
		}
	})
}

func writeIPTool(t *testing.T, dir, body string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(dir, "ip"), []byte(body), 0o755); err != nil {
		t.Fatal(err)
	}
}
