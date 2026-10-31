//go:build parity

package doctor

import (
	"bytes"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"testing"
)

var configPython, _ = exec.LookPath("python3")

func configFixture(t *testing.T, verify bool) (ConfigDiagnostics, string) {
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
	if verify {
		if configPython == "" {
			t.Fatal("python3 not available for reference checksum oracle")
		}
		if err := os.Symlink(configPython, filepath.Join(bin, "python3")); err != nil {
			t.Fatal(err)
		}
	}
	t.Setenv("PATH", bin)
	file := filepath.Join(t.TempDir(), "config.json")
	verificationFile(t, file)
	return ConfigDiagnostics{Present: true, VerifyAddresses: verify}, file
}

func configVectors(t *testing.T) map[string]string {
	t.Helper()
	source, err := os.ReadFile(filepath.Join(verificationRoot(t), "tests", "stack", "lib.sh"))
	if err != nil {
		t.Fatal(err)
	}
	values := make(map[string]string)
	for _, match := range regexp.MustCompile(`(?m)^VALID_(PRIMARY|SUBADDR|INTEGRATED|TARI|TARI_EMOJI|TARI_SINGLE)="([^"]+)"$`).FindAllStringSubmatch(string(source), -1) {
		values[match[1]] = match[2]
	}
	if len(values) != 6 {
		t.Fatalf("public vectors found: %d", len(values))
	}
	return values
}

func runConfigBash(t *testing.T, input ConfigDiagnostics, file, operation string) hostBashResult {
	t.Helper()
	root := verificationRoot(t)
	flag := func(value bool) string {
		if value {
			return "1"
		}
		return "0"
	}
	command := exec.Command(hostParityBash, filepath.Join(root, "tests", "go-parity", "doctor_config_reference.sh"),
		root, operation, flag(input.Appliance), file, input.Variant, input.SSHEnabled, input.Monero, input.Tari,
		flag(input.MoneroKeyOnly), flag(input.TariKeyOnly))
	command.Env = append(hostEnvironment(t), "LC_ALL=C")
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

func compareConfig(t *testing.T, input ConfigDiagnostics, file string) {
	t.Helper()
	result := runConfigBash(t, input, file, "findings")
	findings, err := input.Findings()
	if err != nil {
		t.Fatal(err)
	}
	assertHostFindings(t, result, findings)
}

func compareConfigKind(t *testing.T, input ConfigDiagnostics, file, kind, want string) {
	t.Helper()
	result := runConfigBash(t, input, file, kind)
	if result.code != 0 || result.stderr != "" || result.stdout != want+"\n" {
		t.Fatalf("%s Bash %+v, Go %s", kind, result, strconv.Quote(want))
	}
}
