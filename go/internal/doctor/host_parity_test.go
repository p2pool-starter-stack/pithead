//go:build parity

package doctor

import (
	"errors"
	"os"
	"path/filepath"
	"testing"

	"github.com/p2pool-starter-stack/pithead/go/internal/host"
)

func TestHostEngineParity(t *testing.T) {
	tests := []struct {
		name     string
		override string
		tools    []string
	}{
		{"missing", "", nil},
		{"podman", "", []string{"podman"}},
		{"docker", "", []string{"docker"}},
		{"both", "", []string{"podman", "docker"}},
		{"docker override", "docker", []string{"podman"}},
		{"podman override", "podman", []string{"docker"}},
		{"invalid override", "containerd", []string{"podman"}},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			dir := t.TempDir()
			for _, tool := range test.tools {
				writeLoggedTool(t, dir, tool)
			}
			t.Setenv("PATH", dir)
			t.Setenv("PITHEAD_ENGINE", test.override)
			want := runHostBash(t, "engine", false, filepath.Join(dir, "cpuinfo"), "Linux")
			if want.code != 0 || want.stderr != "" {
				t.Fatalf("Bash = exit %d, stderr %q", want.code, want.stderr)
			}
			if got := host.Engine(); got != want.stdout {
				t.Fatalf("Engine() = %q, want %q", got, want.stdout)
			}
		})
	}
}

func TestHostBootEnabledParity(t *testing.T) {
	tests := []struct {
		engine  string
		enabled string
	}{
		{"podman", "podman.socket"},
		{"podman", ""},
		{"docker", "docker.service"},
		{"docker", "docker.socket"},
		{"docker", ""},
	}
	for _, test := range tests {
		t.Run(test.engine+"/"+test.enabled, func(t *testing.T) {
			dir := t.TempDir()
			log := filepath.Join(dir, "calls")
			writeHostTool(t, dir, "systemctl", "printf '%s\\n' \"$*\" >>\"$SYSTEMCTL_LOG\"\n[ \"${2:-}\" = \"${SYSTEMCTL_OK:-}\" ]\n")
			t.Setenv("PATH", dir)
			t.Setenv("PITHEAD_ENGINE", test.engine)
			t.Setenv("SYSTEMCTL_OK", test.enabled)
			t.Setenv("SYSTEMCTL_LOG", log)
			want := runHostBash(t, "boot-enabled", false, filepath.Join(dir, "cpuinfo"), "Linux")
			wantEnabled := want.code == 0
			got, err := BootEnabled()
			if err != nil || got != wantEnabled {
				t.Fatalf("BootEnabled() = %v, %v; Bash exit = %d", got, err, want.code)
			}
		})
	}
}

func TestHostBootPersistenceParity(t *testing.T) {
	for _, appliance := range []bool{false, true} {
		for _, enabled := range []string{"docker.service", "docker.socket", ""} {
			dir := t.TempDir()
			writeHostTool(t, dir, "systemctl", "[ \"${2:-}\" = \"${SYSTEMCTL_OK:-}\" ]\n")
			t.Setenv("PATH", dir)
			t.Setenv("PITHEAD_ENGINE", "docker")
			t.Setenv("SYSTEMCTL_OK", enabled)
			result := runHostBash(t, "boot", appliance, filepath.Join(dir, "cpuinfo"), "Linux")
			finding, err := BootPersistence(appliance)
			if err != nil {
				t.Fatal(err)
			}
			assertHostFindings(t, result, []Finding{finding})
		}
	}
}

func TestHostBootEnabledMissingSystemctlParity(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("PATH", dir)
	t.Setenv("PITHEAD_ENGINE", "docker")
	result := runHostBash(t, "boot-enabled", false, filepath.Join(dir, "cpuinfo"), "Linux")
	got, err := BootEnabled()
	if result.code == 0 || err != nil || got {
		t.Fatalf("Bash exit = %d, Go enabled = %v, %v", result.code, got, err)
	}
	if _, err := os.Stat(filepath.Join(dir, "systemctl")); !os.IsNotExist(err) {
		t.Fatalf("unexpected systemctl fixture: %v", err)
	}
}

func TestHostBootEnabledUnsupportedLaunchParity(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "systemctl"), []byte("exit 0\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", dir)
	t.Setenv("PITHEAD_ENGINE", "docker")
	result := runHostBash(t, "boot-enabled", false, filepath.Join(dir, "cpuinfo"), "Linux")
	if result.code != 0 {
		t.Fatalf("Bash exit = %d, stderr = %q", result.code, result.stderr)
	}
	if got, err := BootEnabled(); got || !errors.Is(err, ErrUnsupportedProbeInput) {
		t.Fatalf("Go enabled = %v, %v", got, err)
	}
}
