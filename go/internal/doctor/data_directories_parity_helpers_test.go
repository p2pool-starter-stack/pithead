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

type dataDirectoriesFixture struct {
	input   DataDirectories
	envFile string
}

func newDataDirectoriesFixture(t *testing.T) dataDirectoriesFixture {
	t.Helper()
	root := t.TempDir()
	fixture := dataDirectoriesFixture{DataDirectories{Dir: filepath.Join(root, "install"), Completed: "true"}, ".env"}
	bin := filepath.Join(root, "bin")
	for _, dir := range []string{fixture.input.Dir, bin} {
		if err := os.Mkdir(dir, 0o700); err != nil {
			t.Fatal(err)
		}
	}
	for name, path := range map[string]string{"awk": diskToolPaths["awk"], "grep": controlToolPaths["grep"]} {
		if path == "" {
			t.Fatalf("%s missing", name)
		}
		if err := os.Symlink(path, filepath.Join(bin, name)); err != nil {
			t.Fatal(err)
		}
	}
	writeHostTool(t, bin, "uname", "printf 'Linux\\n'\n")
	writeHostTool(t, bin, "id", "printf 'fixture\\n'\n")
	t.Setenv("PATH", bin)
	return fixture
}

func (fixture dataDirectoriesFixture) reference(t *testing.T, operation string) hostBashResult {
	t.Helper()
	root := verificationRoot(t)
	appliance := "0"
	if fixture.input.Appliance {
		appliance = "1"
	}
	args := []string{filepath.Join(root, "tests", "go-parity", "doctor_data_directories_reference.sh"), root, operation,
		fixture.input.Dir, appliance, fixture.input.Completed, fixture.envFile}
	command := exec.Command(hostParityBash, append(args, fixture.input.Dirs...)...)
	command.Dir = fixture.input.Dir
	command.Env = hostEnvironment(t)
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
	return hostBashResult{stdout.String(), stderr.String(), code}
}

func (fixture dataDirectoriesFixture) compare(t *testing.T, operation string) {
	t.Helper()
	result := fixture.reference(t, operation)
	switch operation {
	case "findings":
		findings, err := fixture.input.Findings()
		if err != nil {
			t.Fatal(err)
		}
		assertHostFindings(t, result, findings)
	case "deployment":
		findings, err := (Deployment{Dir: fixture.input.Dir, EnvFile: fixture.envFile,
			Completed: fixture.input.Completed, Appliance: fixture.input.Appliance}).Findings()
		if err != nil {
			t.Fatal(err)
		}
		assertHostFindings(t, result, findings)
	case "missing":
		missing, err := fixture.input.Missing()
		if err != nil {
			t.Fatal(err)
		}
		var stdout strings.Builder
		for _, line := range missing {
			stdout.WriteString(line + "\n")
		}
		if result.code != 0 || result.stderr != "" || result.stdout != stdout.String() {
			t.Fatalf("Bash %+v, Go missing %q", result, stdout.String())
		}
	case "warnings":
		warnings, err := fixture.input.Warnings()
		if err != nil {
			t.Fatal(err)
		}
		var stderr strings.Builder
		for _, line := range warnings {
			stderr.WriteString("[WARNING] " + line + "\n")
		}
		if result.code != 0 || result.stdout != "" || result.stderr != stderr.String() {
			t.Fatalf("Bash %+v, Go warnings %q", result, stderr.String())
		}
	default:
		t.Fatalf("unknown operation %q", operation)
	}
}
