//go:build parity

package doctor

import (
	"bytes"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
)

func newOnionFixture(t *testing.T) OnionAddresses {
	t.Helper()
	bin := t.TempDir()
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
	return OnionAddresses{
		Profiles: "local_node,local_tari", Addresses: []string{"monero.onion", "tari.onion", "pool.onion"},
		DashboardEnabled: "true", DashboardAddress: "dashboard.onion", Program: "./pithead",
	}
}

func runOnionBash(t *testing.T, input OnionAddresses, operation string) hostBashResult {
	t.Helper()
	root := verificationRoot(t)
	appliance := "0"
	if input.Appliance {
		appliance = "1"
	}
	args := []string{"-c", `source "$1" "${@:2}"`, input.Program,
		filepath.Join(root, "tests", "go-parity", "doctor_onion_reference.sh"), root, operation, appliance,
		input.Profiles, input.DashboardEnabled, input.DashboardAddress, input.ClientAuth}
	command := exec.Command(hostParityBash, append(args, input.Addresses...)...)
	command.Dir = root
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

func compareOnionFindings(t *testing.T, input OnionAddresses) {
	t.Helper()
	result := runOnionBash(t, input, "findings")
	findings, err := input.Findings()
	if err != nil {
		t.Fatal(err)
	}
	assertHostFindings(t, result, findings)
}

func compareOnionStatus(t *testing.T, input OnionAddresses) {
	t.Helper()
	result := runOnionBash(t, input, "dashboard")
	status, err := input.DashboardStatus()
	wantCode := 0
	if status == "" {
		wantCode = 1
	}
	if err != nil || result.code != wantCode || result.stderr != "" || result.stdout != status {
		t.Fatalf("Bash %+v, Go status %q, %v", result, status, err)
	}
}
