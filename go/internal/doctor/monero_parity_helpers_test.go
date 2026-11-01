//go:build parity

package doctor

import (
	"bytes"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"testing"
)

var moneroParityJQ, _ = exec.LookPath("jq")

type moneroParityFixture struct {
	MoneroRPC
	dir string
}

func newMoneroParityFixture(t *testing.T) moneroParityFixture {
	t.Helper()
	input := moneroParityFixture{MoneroRPC: MoneroRPC{URL: "http://rpc.invalid", Now: 200000}, dir: t.TempDir()}
	if moneroParityJQ == "" {
		t.Fatal("jq is required")
	}
	if err := os.Symlink(moneroParityJQ, filepath.Join(input.dir, "jq")); err != nil {
		t.Fatal(err)
	}
	writeHostTool(t, input.dir, "uname", "printf 'Linux\\n'\n")
	writeHostTool(t, input.dir, "id", "printf 'fixture\\n'\n")
	writeHostTool(t, input.dir, "docker", `
dir=${0%/*}
printf '%s\n' docker "$@" >>"$dir/calls.log"
case "$1" in
ps) /bin/cat "$dir/running.value"; exit "$(/bin/cat "$dir/running.code")" ;;
exec) /bin/cat "$dir/peers.value"; exit "$(/bin/cat "$dir/peers.code")" ;;
*) exit 99 ;;
esac
`)
	writeHostTool(t, input.dir, "curl", `
dir=${0%/*}
printf '%s\n' curl "$@" >>"$dir/calls.log"
for last in "$@"; do :; done
case "$last" in
*/get_info) /bin/cat "$dir/info.value"; exit "$(/bin/cat "$dir/info.code")" ;;
*/json_rpc) /bin/cat "$dir/header.value"; exit "$(/bin/cat "$dir/header.code")" ;;
*) exit 99 ;;
esac
`)
	for _, name := range []string{"running", "peers", "info", "header"} {
		input.write(t, name+".code", "0")
	}
	input.write(t, "running.value", "cid\n")
	input.write(t, "peers.value", `{"outgoing":8,"incoming":2}`)
	input.write(t, "info.value", `{"status":"OK","synchronized":true,"outgoing_connections_count":0,"incoming_connections_count":0}`)
	input.write(t, "header.value", `{"result":{"block_header":{"timestamp":199900}}}`)
	input.write(t, "calls.log", "")
	t.Setenv("PATH", input.dir)
	return input
}

func (input moneroParityFixture) write(t *testing.T, name, value string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(input.dir, name), []byte(value), 0o600); err != nil {
		t.Fatal(err)
	}
}

func (input moneroParityFixture) reference(t *testing.T, operation string) hostBashResult {
	t.Helper()
	root := verificationRoot(t)
	surface := "0"
	if input.Appliance {
		surface = "1"
	}
	cmd := exec.Command(hostParityBash, filepath.Join(root, "tests", "go-parity", "doctor_monero_reference.sh"),
		root, operation, input.dir, surface, input.User, input.Password, input.URL, strconv.FormatInt(input.Now, 10))
	cmd.Env = []string{"PATH=" + input.dir, "LC_ALL=C", "TMPDIR=" + t.TempDir()}
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

func (input moneroParityFixture) calls(t *testing.T) string {
	t.Helper()
	value, err := os.ReadFile(filepath.Join(input.dir, "calls.log"))
	if err != nil {
		t.Fatal(err)
	}
	input.write(t, "calls.log", "")
	return string(value)
}

func compareMonero(t *testing.T, input moneroParityFixture, operation string) {
	t.Helper()
	want := input.reference(t, operation)
	wantCalls := input.calls(t)
	var err error
	if operation == "counts" {
		var counts string
		counts, err = input.PeerCounts()
		if counts != "" {
			counts += "\n"
		}
		if err == nil && (want.code != 0 || want.stdout != counts || want.stderr != "") {
			t.Fatal("peer-count output differs from Bash")
		}
	} else {
		var findings []Finding
		if operation == "sync" {
			findings, err = input.Findings()
		} else {
			findings, err = input.PeersAndTip()
		}
		if err == nil {
			assertHostFindings(t, want, findings)
		}
	}
	if err != nil {
		t.Fatal(err)
	}
	if got := input.calls(t); got != wantCalls {
		t.Fatal("probe command order or arguments differ from Bash")
	}
}
