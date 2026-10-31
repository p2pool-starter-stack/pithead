package doctor

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestContainerEngine(t *testing.T) {
	for _, test := range []struct {
		name, override, tools, status, message, calls string
	}{
		{"missing", "", "", "info", "Skipped — docker is not installed.", ""},
		{"docker", "", "docker", "ok", "Docker daemon is reachable.", "info\n"},
		{"podman", "", "podman", "ok", "Container engine (podman) is reachable.", "info\n"},
		{"docker wins", "", "docker podman", "ok", "Docker daemon is reachable.", "info\n"},
		{"override", "podman", "docker podman", "ok", "Container engine (podman) is reachable.", "info\n"},
		{"missing override", "docker", "podman", "info", "Skipped — docker is not installed.", ""},
		{"missing podman", "podman", "docker", "fail", "Container engine (podman) is not reachable", ""},
	} {
		t.Run(test.name, func(t *testing.T) {
			dir := t.TempDir()
			for _, tool := range strings.Fields(test.tools) {
				writeDaemonTool(t, dir, tool, true)
			}
			log := filepath.Join(dir, "calls")
			t.Setenv("PATH", dir)
			t.Setenv("PITHEAD_ENGINE", test.override)
			t.Setenv("DAEMON_CALLS", log)
			t.Setenv("DAEMON_EXIT", "0")
			finding, err := ContainerEngine(false)
			if err != nil || finding.ID != "container-engine" || finding.Status != test.status || !strings.Contains(finding.Message, test.message) {
				t.Fatalf("ContainerEngine = %+v, %v", finding, err)
			}
			calls, err := os.ReadFile(log)
			if err != nil && !os.IsNotExist(err) {
				t.Fatal(err)
			}
			if string(calls) != test.calls {
				t.Fatalf("calls = %q, want %q", calls, test.calls)
			}
		})
	}
}

func TestContainerEngineFailures(t *testing.T) {
	for _, engine := range []string{"docker", "podman"} {
		for _, appliance := range []bool{false, true} {
			dir := t.TempDir()
			writeDaemonTool(t, dir, engine, true)
			t.Setenv("PATH", dir)
			t.Setenv("PITHEAD_ENGINE", engine)
			t.Setenv("DAEMON_CALLS", filepath.Join(dir, "calls"))
			t.Setenv("DAEMON_EXIT", "7")
			finding, err := ContainerEngine(appliance)
			if err != nil || finding.Status != "fail" || strings.Contains(finding.Message, "system copy is faulty") != appliance {
				t.Fatalf("failure finding = %+v, %v", finding, err)
			}
		}
	}
}

func TestContainerEngineUnsupportedLaunch(t *testing.T) {
	dir := t.TempDir()
	writeDaemonTool(t, dir, "docker", false)
	t.Setenv("PATH", dir)
	t.Setenv("PITHEAD_ENGINE", "docker")
	if got, err := ContainerEngine(false); got != (Finding{}) || !errors.Is(err, ErrUnsupportedProbeInput) {
		t.Fatalf("unsupported launch = %+v, %v", got, err)
	}
}

func TestContainerEngineRelativePATH(t *testing.T) {
	dir := t.TempDir()
	writeDaemonTool(t, dir, "docker", true)
	writeDaemonTool(t, dir, "podman", true)
	cwd, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	path, err := filepath.Rel(cwd, dir)
	if err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", path)
	for _, override := range []string{"", "docker", "podman"} {
		t.Setenv("PITHEAD_ENGINE", override)
		if got, err := ContainerEngine(false); got != (Finding{}) || !errors.Is(err, ErrUnsupportedProbeInput) {
			t.Fatalf("override %q = %+v, %v", override, got, err)
		}
	}
}

func writeDaemonTool(t *testing.T, dir, name string, shebang bool) {
	t.Helper()
	body := "exit 0\n"
	if shebang {
		body = "#!/bin/sh\nprintf '%s\\n' \"$*\" >>\"$DAEMON_CALLS\"\nprintf 'quiet stdout\\n'\nprintf 'quiet stderr\\n' >&2\nexit \"$DAEMON_EXIT\"\n"
	}
	if err := os.WriteFile(filepath.Join(dir, name), []byte(body), 0o700); err != nil {
		t.Fatal(err)
	}
}
