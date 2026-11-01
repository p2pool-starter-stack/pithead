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

type containerParityFixture struct {
	dir  string
	hold bool
}

func newContainerParityFixture(t *testing.T, engine string) containerParityFixture {
	t.Helper()
	input := containerParityFixture{dir: t.TempDir()}
	writeHostTool(t, input.dir, "uname", "printf 'Linux\\n'\n")
	writeHostTool(t, input.dir, "id", "printf 'fixture\\n'\n")
	writeHostTool(t, input.dir, "fake-engine", `
dir=${0%/*}
printf '%s\n' "${0##*/}" "$@" >>"$dir/calls.log"
case "$1" in
ps) /bin/cat "$dir/ps.value"; exit "$(/bin/cat "$dir/ps.code")" ;;
compose)
    step=$(/bin/cat "$dir/step")
    step=$((step + 1))
    printf '%s\n' "$step" >"$dir/step"
    /bin/cat "$dir/ids$step.value"
    exit "$(/bin/cat "$dir/ids$step.code")"
    ;;
inspect)
    step=$(/bin/cat "$dir/step")
    /bin/cat "$dir/inspect$step.value"
    exit "$(/bin/cat "$dir/inspect$step.code")"
    ;;
*) exit 99 ;;
esac
`)
	for _, name := range []string{"docker", "podman"} {
		if err := os.Symlink("fake-engine", filepath.Join(input.dir, name)); err != nil {
			t.Fatal(err)
		}
	}
	writeHostTool(t, input.dir, "sleep", `
printf '%s\n' sleep "$@" >>"${0%/*}/calls.log"
exit "$(/bin/cat "${0%/*}/sleep.code")"
`)
	for _, name := range []string{"ps", "ids1", "ids2", "inspect1", "inspect2", "sleep"} {
		input.write(t, name+".code", "0")
	}
	input.write(t, "ps.value", "monerod\trunning\tUp (healthy)\n")
	input.write(t, "ids1.value", "a\n")
	input.write(t, "ids2.value", "a\n")
	row := "a\t/caddy\trunning\t1\t2026-10-01T00:00:00Z\n"
	input.write(t, "inspect1.value", row)
	input.write(t, "inspect2.value", row)
	input.reset(t)
	t.Setenv("PATH", input.dir)
	t.Setenv("PITHEAD_ENGINE", engine)
	return input
}

func (input containerParityFixture) write(t *testing.T, name, value string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(input.dir, name), []byte(value), 0o600); err != nil {
		t.Fatal(err)
	}
}

func (input containerParityFixture) reset(t *testing.T) {
	t.Helper()
	input.write(t, "calls.log", "")
	input.write(t, "step", "0\n")
}

func (input containerParityFixture) reference(t *testing.T, operation string, values ...string) hostBashResult {
	t.Helper()
	root := verificationRoot(t)
	hold := "0"
	if input.hold {
		hold = "1"
	}
	for len(values) < 4 {
		values = append(values, "")
	}
	args := []string{filepath.Join(root, "tests", "go-parity", "doctor_containers_reference.sh"), root, operation, input.dir, hold}
	cmd := exec.Command(hostParityBash, append(args, values...)...)
	cmd.Dir = input.dir
	cmd.Env = []string{"PATH=" + input.dir, "PITHEAD_ENGINE=" + os.Getenv("PITHEAD_ENGINE"), "LC_ALL=C", "TMPDIR=" + t.TempDir()}
	var stdout, stderr bytes.Buffer
	cmd.Stdout, cmd.Stderr = &stdout, &stderr
	code := 0
	if err := cmd.Run(); err != nil {
		var status *exec.ExitError
		if !errors.As(err, &status) {
			t.Fatal(err)
		}
		code = status.ExitCode()
	}
	return hostBashResult{stdout.String(), stderr.String(), code}
}

func (input containerParityFixture) calls(t *testing.T) string {
	t.Helper()
	value, err := os.ReadFile(filepath.Join(input.dir, "calls.log"))
	if err != nil {
		t.Fatal(err)
	}
	return string(value)
}

func compareContainerFindings(t *testing.T, input containerParityFixture, operation string) {
	t.Helper()
	want := input.reference(t, operation)
	wantCalls := input.calls(t)
	input.reset(t)
	var findings []Finding
	var err error
	if operation == "revenue" {
		findings, err = (RevenueContainers{MigrationHold: input.hold}).Findings()
	} else {
		findings, err = ContainerRestarts(input.dir)
	}
	if err != nil {
		t.Fatal(err)
	}
	assertHostFindings(t, want, findings)
	if calls := input.calls(t); calls != wantCalls {
		t.Fatalf("calls: Bash %q; Go %q", wantCalls, calls)
	}
}

func compareContainerVerdict(t *testing.T, input containerParityFixture, name, state, status, hold string) {
	t.Helper()
	want := input.reference(t, "verdict", name, state, status, hold)
	got, err := RevenueContainerVerdict(name, state, status, hold)
	if err != nil || want.code != 0 || want.stdout != got+"\n" || want.stderr != "" || strings.Contains(got, "\x00") {
		t.Fatalf("Bash %#v; Go %q, %v", want, got, err)
	}
}
