package doctor

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestBootEnabled(t *testing.T) {
	tests := []struct {
		name   string
		engine string
		ok     string
		want   bool
		calls  string
	}{
		{"podman enabled", "podman", "podman.socket", true, "is-enabled podman.socket\n"},
		{"podman disabled", "podman", "", false, "is-enabled podman.socket\n"},
		{"docker service", "docker", "docker.service", true, "is-enabled docker.service\n"},
		{"docker socket", "docker", "docker.socket", true, "is-enabled docker.service\nis-enabled docker.socket\n"},
		{"docker disabled", "docker", "", false, "is-enabled docker.service\nis-enabled docker.socket\n"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			dir := t.TempDir()
			log := filepath.Join(dir, "calls")
			writeSystemctl(t, dir)
			t.Setenv("PATH", dir)
			t.Setenv("PITHEAD_ENGINE", test.engine)
			t.Setenv("SYSTEMCTL_OK", test.ok)
			t.Setenv("SYSTEMCTL_LOG", log)

			got, err := BootEnabled()
			if err != nil || got != test.want {
				t.Fatalf("got %v, %v; want %v", got, err, test.want)
			}
			content, err := os.ReadFile(log)
			if err != nil {
				t.Fatal(err)
			}
			if string(content) != test.calls {
				t.Fatalf("calls %q, want %q", content, test.calls)
			}
		})
	}
}

func TestBootEnabledMissingSystemctl(t *testing.T) {
	t.Setenv("PATH", t.TempDir())
	t.Setenv("PITHEAD_ENGINE", "docker")
	if got, err := BootEnabled(); err != nil || got {
		t.Fatalf("got %v, %v", got, err)
	}
}

func TestBootEnabledUnsupportedLaunch(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "systemctl"), []byte("exit 0\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", dir)
	t.Setenv("PITHEAD_ENGINE", "docker")
	if got, err := BootEnabled(); got || !errors.Is(err, ErrUnsupportedProbeInput) {
		t.Fatalf("got %v, %v", got, err)
	}
	if got, err := BootPersistence(false); got != (Finding{}) || !errors.Is(err, ErrUnsupportedProbeInput) {
		t.Fatalf("got %#v, %v", got, err)
	}
}

func TestBootPersistence(t *testing.T) {
	dir := t.TempDir()
	writeSystemctl(t, dir)
	t.Setenv("PATH", dir)
	t.Setenv("PITHEAD_ENGINE", "docker")
	t.Setenv("SYSTEMCTL_LOG", filepath.Join(dir, "calls"))

	t.Setenv("SYSTEMCTL_OK", "docker.service")
	if got, err := BootPersistence(false); err != nil || got != (Finding{"container-engine-boot", "ok", "Docker is enabled to start at boot — the stack will come back after a reboot."}) {
		t.Fatalf("enabled finding: %#v, %v", got, err)
	}

	t.Setenv("SYSTEMCTL_OK", "")
	wantDIY := Finding{"container-engine-boot", "warn", "The container engine is NOT enabled to start at boot — after a power loss/reboot the stack won't restart. Fix: 'sudo systemctl enable --now docker' (docker) or 'sudo systemctl enable --now podman.socket' (podman)."}
	if got, err := BootPersistence(false); err != nil || got != wantDIY {
		t.Fatalf("DIY finding: %#v, %v", got, err)
	}
	wantAppliance := Finding{"container-engine-boot", "warn", "The container engine is NOT enabled to start at boot — after a power loss or reboot the mining stack won't restart. This machine enables it at install time, so this system copy is faulty."}
	if got, err := BootPersistence(true); err != nil || got != wantAppliance {
		t.Fatalf("appliance finding: %#v, %v", got, err)
	}
}

func writeSystemctl(t *testing.T, dir string) {
	t.Helper()
	script := strings.Join([]string{
		"#!/bin/sh",
		"printf '%s\\n' \"$*\" >>\"$SYSTEMCTL_LOG\"",
		"[ \"${2:-}\" = \"${SYSTEMCTL_OK:-}\" ]",
		"",
	}, "\n")
	if err := os.WriteFile(filepath.Join(dir, "systemctl"), []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
}
