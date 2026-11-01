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
	"strings"
	"testing"
)

type torHistoryParityFixture struct {
	TorCircuitHistory
	dir string
}

func newTorHistoryParityFixture(t *testing.T) torHistoryParityFixture {
	t.Helper()
	dir := t.TempDir()
	mount := filepath.Join(dir, "tor")
	if err := os.Mkdir(mount, 0o700); err != nil {
		t.Fatal(err)
	}
	input := torHistoryParityFixture{TorCircuitHistory{Mount: mount, MountAvailable: true}, dir}
	trace := "printf '%s\\n' \"${0##*/}\" \"$@\" >>\"${0%/*}/tools.log\"\n"
	writeHostTool(t, dir, "uname", "printf 'Linux\\n'\n")
	writeHostTool(t, dir, "id", trace+"/bin/cat \"$0.value\"\n")
	writeHostTool(t, dir, "docker", trace+"/bin/cat \"$0.value\"\n")
	writeHostTool(t, dir, "sudo", trace+
		"if [ \"$1\" = -n ]; then exit \"$(/bin/cat \"$0.code\")\"; fi\n"+
		"case \"$1\" in\n"+
		"test) shift; /bin/test \"$@\" ;;\n"+
		"grep) shift; if [ \"$2\" = '^CircuitBuildTimeBin ' ] && [ -f \"$0.grep-error\" ]; then exit 2; fi; exec \"$0.grep\" \"$@\" ;;\n"+
		"*) exit 99 ;;\nesac\n")
	if err := os.Symlink(controlToolPaths["grep"], filepath.Join(dir, "sudo.grep")); err != nil {
		t.Fatal(err)
	}
	writeHostTool(t, dir, "curl", trace+
		"case \"${10}\" in\n*google*) exit \"$(/bin/cat \"$0.first\")\" ;;\n*cloudflare*) exit \"$(/bin/cat \"$0.second\")\" ;;\n*) exit 99 ;;\nesac\n")
	for name, value := range map[string]string{"id.value": "0\n", "docker.value": "cid\n", "sudo.code": "0", "curl.first": "1", "curl.second": "1"} {
		input.write(t, name, value)
	}
	input.write(t, "tor/state", "CircuitBuildAbandonedCount 1000\nTotalBuildTimes 1000\n")
	t.Setenv("PATH", dir)
	return input
}

func (input torHistoryParityFixture) write(t *testing.T, name, value string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(input.dir, name), []byte(value), 0o600); err != nil {
		t.Fatal(err)
	}
}

func (input torHistoryParityFixture) reference(t *testing.T, operation string) hostBashResult {
	t.Helper()
	root := verificationRoot(t)
	surface, mountOK := "0", "0"
	if input.Appliance {
		surface = "1"
	}
	if input.MountAvailable {
		mountOK = "1"
	}
	cmd := exec.Command(hostParityBash, filepath.Join(root, "tests", "go-parity", "tor_history_reference.sh"),
		root, operation, input.dir, "", "0", "0", input.Prefix, input.Mount, surface, mountOK)
	cmd.Env = []string{"PATH=" + input.dir, "LC_ALL=C", "TMPDIR=" + t.TempDir()}
	var out, diagnostics bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &diagnostics
	code := 0
	if err := cmd.Run(); err != nil {
		var status *exec.ExitError
		if !errors.As(err, &status) {
			t.Fatal(err)
		}
		code = status.ExitCode()
	}
	return hostBashResult{out.String(), diagnostics.String(), code}
}

var torHistoryAuthPattern = regexp.MustCompile(`^tor-recover-[0-9]+-([0-9]+)-([0-9]+):isolate$`)

func (input torHistoryParityFixture) calls(t *testing.T) string {
	t.Helper()
	path := filepath.Join(input.dir, "tools.log")
	data, err := os.ReadFile(path)
	if err != nil && !os.IsNotExist(err) {
		t.Fatal(err)
	}
	input.write(t, "tools.log", "")
	lines := strings.Split(string(data), "\n")
	for i, line := range lines {
		if i == 0 || lines[i-1] != "--proxy-user" {
			continue
		}
		parts := torHistoryAuthPattern.FindStringSubmatch(line)
		if parts == nil {
			t.Fatalf("invalid isolation auth: %q", line)
		}
		for _, part := range parts[1:] {
			value, err := strconv.Atoi(part)
			if err != nil || value > 32767 {
				t.Fatalf("invalid RANDOM field: %q", part)
			}
		}
		lines[i] = "<fresh-isolation-auth>"
	}
	return strings.Join(lines, "\n")
}

func compareTorHistory(t *testing.T, input torHistoryParityFixture, operation string) {
	t.Helper()
	want := input.reference(t, operation)
	wantCalls := input.calls(t)
	var err error
	if operation == "doctor" {
		var findings []Finding
		findings, err = input.Findings()
		if err == nil {
			assertHostFindings(t, want, findings)
		}
	} else {
		var got bool
		if operation == "saturated" {
			got, err = TorStateSaturated(input.Mount + "/state")
		} else {
			got, err = TorRecoveryEgressDown(input.Prefix)
		}
		if err == nil && (got != (want.code == 0) || want.code > 1 || want.stdout != "" || want.stderr != "") {
			t.Fatalf("Bash = %#v; Go = %v", want, got)
		}
	}
	if err != nil {
		t.Fatal(err)
	}
	if got := input.calls(t); got != wantCalls {
		t.Fatalf("calls: Bash %q; Go %q", wantCalls, got)
	}
}
