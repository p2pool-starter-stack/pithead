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

type hostBashResult struct {
	stdout string
	stderr string
	code   int
}

var hostParityBash, _ = exec.LookPath("bash")

func runHostBash(t *testing.T, operation string, appliance bool, cpuinfo, osType string) hostBashResult {
	t.Helper()
	if hostParityBash == "" {
		t.Fatal("bash not found")
	}
	dir := strings.Split(os.Getenv("PATH"), string(os.PathListSeparator))[0]
	writeHostTool(t, dir, "uname", "printf '%s\\n' \"$REFERENCE_OS\"\n")
	writeHostTool(t, dir, "id", "printf '%s\\n' fixture\n")
	root, err := filepath.Abs(filepath.Join("..", "..", ".."))
	if err != nil {
		t.Fatal(err)
	}
	applianceValue := "0"
	if appliance {
		applianceValue = "1"
	}
	command := exec.Command(hostParityBash, filepath.Join(root, "tests", "go-parity", "doctor_host_reference.sh"), root, operation, applianceValue, cpuinfo, osType)
	command.Env = append(hostEnvironment(t), "REFERENCE_OS="+osType)
	var stdout, stderr bytes.Buffer
	command.Stdout, command.Stderr = &stdout, &stderr
	err = command.Run()
	code := 0
	if err != nil {
		var exit *exec.ExitError
		if !errors.As(err, &exit) {
			t.Fatal(err)
		}
		code = exit.ExitCode()
	}
	return hostBashResult{stdout.String(), stderr.String(), code}
}

func hostEnvironment(t *testing.T) []string {
	t.Helper()
	values := []string{"PATH", "PITHEAD_ENGINE", "SYSTEMCTL_OK", "SYSTEMCTL_LOG", "TOOL_LOG", "JQ_OUTPUT", "JQ_EXIT", "DOCKER_OUTPUT", "DOCKER_EXIT", "COMPOSE_EXIT", "SYSCTL_OUTPUT", "SYSCTL_EXIT"}
	environment := []string{"TMPDIR=" + t.TempDir()}
	for _, name := range values {
		environment = append(environment, name+"="+os.Getenv(name))
	}
	return environment
}

func assertHostFindings(t *testing.T, result hostBashResult, findings []Finding) {
	t.Helper()
	var rows, human strings.Builder
	for _, finding := range findings {
		rows.WriteString(finding.Status + "\t" + finding.Message + "\t" + finding.ID + "\n")
		switch finding.Status {
		case "ok":
			human.WriteString("  ✓ OK   " + finding.Message + "\n")
		case "warn":
			human.WriteString("  ⚠ WARN " + finding.Message + "\n")
		case "fail":
			human.WriteString("  ✗ FAIL " + finding.Message + "\n")
		case "info":
			human.WriteString("  •      " + finding.Message + "\n")
		}
	}
	if result.code != 0 || result.stdout != rows.String() || result.stderr != human.String() {
		t.Fatalf("Bash = exit %d, rows %q, human %q; Go rows %q, human %q", result.code, result.stdout, result.stderr, rows.String(), human.String())
	}
}

func writeHostTool(t *testing.T, dir, name, body string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(dir, name), []byte("#!/bin/sh\n"+body), 0o755); err != nil {
		t.Fatal(err)
	}
}

func writeLoggedTool(t *testing.T, dir, name string) {
	t.Helper()
	writeHostTool(t, dir, name, "[ -z \"${TOOL_LOG:-}\" ] || printf '"+name+" %s\\n' \"$*\" >>\"$TOOL_LOG\"\n")
}
