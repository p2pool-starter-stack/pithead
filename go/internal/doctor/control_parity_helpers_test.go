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

var controlToolPaths = func() map[string]string {
	paths := make(map[string]string)
	for _, name := range []string{"sed", "head", "grep", "dirname", "basename", "tr"} {
		paths[name], _ = exec.LookPath(name)
	}
	return paths
}()

type controlFixture struct {
	input  ControlUnits
	bin    string
	marker string
}

func newControlFixture(t *testing.T) controlFixture {
	t.Helper()
	root := t.TempDir()
	fixture := controlFixture{ControlUnits{
		InstallDir: filepath.Join(root, "install"), UnitDir: filepath.Join(root, "units"),
		Enabled: "true", OS: "Linux",
	}, filepath.Join(root, "bin"), filepath.Join(root, "marker")}
	fixture.input.ControlDir = filepath.Join(fixture.input.InstallDir, "data", "control")
	for _, dir := range []string{fixture.input.InstallDir, fixture.input.UnitDir, fixture.bin} {
		if err := os.MkdirAll(dir, 0o700); err != nil {
			t.Fatal(err)
		}
	}
	for name, path := range controlToolPaths {
		if path == "" {
			t.Fatalf("%s missing", name)
		}
		if err := os.Symlink(path, filepath.Join(fixture.bin, name)); err != nil {
			t.Fatal(err)
		}
	}
	writeHostTool(t, fixture.bin, "uname", "printf '%s\\n' \"$CONTROL_OS\"\n")
	writeHostTool(t, fixture.bin, "id", "printf 'fixture\\n'\n")
	writeHostTool(t, fixture.bin, "systemctl", "printf 'unexpected call\\n' >>\"$CONTROL_SYSTEMCTL_LOG\"\nexit 99\n")
	t.Setenv("PATH", fixture.bin)
	t.Setenv("CONTROL_SYSTEMCTL_LOG", filepath.Join(fixture.bin, "calls"))
	return fixture
}

func (fixture controlFixture) reference(t *testing.T, operation, enabled, service, verb string) hostBashResult {
	t.Helper()
	surface := "0"
	if fixture.input.Appliance {
		surface = "1"
	}
	root := verificationRoot(t)
	command := exec.Command(hostParityBash, filepath.Join(root, "tests", "go-parity", "doctor_control_reference.sh"),
		root, operation, surface, fixture.input.InstallDir, fixture.input.UnitDir, enabled,
		fixture.input.ControlDir, fixture.marker, fixture.input.OS, service, verb)
	command.Dir = fixture.input.InstallDir
	command.Env = append(hostEnvironment(t), "CONTROL_SYSTEMCTL_LOG="+os.Getenv("CONTROL_SYSTEMCTL_LOG"), "CONTROL_OS="+fixture.input.OS)
	var stdout, stderr bytes.Buffer
	command.Stdout, command.Stderr = &stdout, &stderr
	code := 0
	if err := command.Run(); err != nil {
		var status *exec.ExitError
		if !errors.As(err, &status) {
			t.Fatal(err)
		}
		code = status.ExitCode()
	}
	if calls := verificationCalls(t, os.Getenv("CONTROL_SYSTEMCTL_LOG")); calls != "" {
		t.Fatalf("systemctl was executed: %q", calls)
	}
	return hostBashResult{stdout.String(), stderr.String(), code}
}

func assertControlFinding(t *testing.T, result hostBashResult, finding Finding, section bool) {
	t.Helper()
	if calls := verificationCalls(t, os.Getenv("CONTROL_SYSTEMCTL_LOG")); calls != "" {
		t.Fatalf("systemctl was executed: %q", calls)
	}
	if section {
		const heading = "\nDashboard control channel:\n"
		if !strings.HasPrefix(result.stderr, heading) {
			t.Fatalf("missing control section: %q", result.stderr)
		}
		result.stderr = strings.TrimPrefix(result.stderr, heading)
	}
	var findings []Finding
	if finding.ID != "" {
		findings = append(findings, finding)
	}
	assertHostFindings(t, result, findings)
}
