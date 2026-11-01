//go:build parity

package nodeprobe

import (
	"bytes"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"testing"
)

var parityBash, _ = exec.LookPath("bash")
var parityJQ, _ = exec.LookPath("jq")

type rpcFixture struct {
	MoneroRPC
	dir string
}

type rpcObservation struct {
	result string
	calls  string
	stdin  string
}

func newRPCFixture(t *testing.T) rpcFixture {
	t.Helper()
	if parityBash == "" || parityJQ == "" {
		t.Fatal("Bash and jq are required")
	}
	fixture := rpcFixture{MoneroRPC: MoneroRPC{Host: "rpc.invalid", Port: "18081"}, dir: t.TempDir()}
	if err := os.Symlink(parityJQ, filepath.Join(fixture.dir, "jq")); err != nil {
		t.Fatal(err)
	}
	fixture.tool(t, "timeout", `
dir=${0%/*}
printf '%s\0' timeout "$@" >>"$dir/calls.log"
code=$(/bin/cat "$dir/timeout.code")
if [ "$code" != 0 ]; then
    /bin/cat "$dir/response.value"
    exit "$code"
fi
shift
exec "$@"
`)
	fixture.tool(t, "curl", `
dir=${0%/*}
printf '%s\0' curl "$@" >>"$dir/calls.log"
/bin/cat >"$dir/stdin.log"
/bin/cat "$dir/response.value"
/bin/cat "$dir/curl.stderr" >&2
exit "$(/bin/cat "$dir/curl.code")"
`)
	for name, value := range map[string]string{
		"timeout.code": "0", "curl.code": "0", "calls.log": "", "stdin.log": "", "curl.stderr": "",
		"response.value": `{"status":"OK","nettype":"mainnet","height":10,"target_height":20}` + "\n200",
	} {
		fixture.write(t, name, value)
	}
	t.Setenv("PATH", fixture.dir)
	return fixture
}

func (fixture rpcFixture) write(t *testing.T, name, value string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(fixture.dir, name), []byte(value), 0o600); err != nil {
		t.Fatal(err)
	}
}

func (fixture rpcFixture) tool(t *testing.T, name, body string) {
	t.Helper()
	path := filepath.Join(fixture.dir, name)
	if err := os.WriteFile(path, []byte("#!/bin/sh\n"+body), 0o755); err != nil {
		t.Fatal(err)
	}
}

func (fixture rpcFixture) observation(t *testing.T, result string) rpcObservation {
	t.Helper()
	values := make([]string, 2)
	for i, name := range []string{"calls.log", "stdin.log"} {
		data, err := os.ReadFile(filepath.Join(fixture.dir, name))
		if err != nil {
			t.Fatal(err)
		}
		values[i] = string(data)
		fixture.write(t, name, "")
	}
	return rpcObservation{result, values[0], values[1]}
}

func (fixture rpcFixture) reference(t *testing.T) (rpcObservation, string) {
	t.Helper()
	config := map[string]any{"monero": map[string]string{"node_username": fixture.User, "node_password": fixture.Password}}
	encoded, err := json.Marshal(config)
	if err != nil {
		t.Fatal(err)
	}
	fixture.write(t, "config.json", string(encoded))
	_, file, _, _ := runtime.Caller(0)
	root := filepath.Clean(filepath.Join(filepath.Dir(file), "..", "..", ".."))
	cmd := exec.Command(parityBash, filepath.Join(root, "tests", "go-parity", "node_monero_reference.sh"),
		root, fixture.dir, fixture.Host, fixture.Port, fixture.MaxFileSize)
	cmd.Env = []string{"PATH=" + fixture.dir, "LC_ALL=C", "TMPDIR=" + t.TempDir()}
	var stdout, stderr bytes.Buffer
	cmd.Stdout, cmd.Stderr = &stdout, &stderr
	if err := cmd.Run(); err != nil {
		t.Fatal("Bash RPC oracle failed to execute")
	}
	return fixture.observation(t, stdout.String()), stderr.String()
}

func compareRPC(t *testing.T, fixture rpcFixture) {
	t.Helper()
	want, diagnostic := fixture.reference(t)
	if diagnostic != "" {
		t.Fatal("Bash RPC oracle exposed a diagnostic")
	}
	reason, err := fixture.Check()
	if err != nil {
		t.Fatal(err)
	}
	result := "1\n" + reason + "\n"
	if reason == "ok" {
		result = "0\nok\n"
	}
	got := fixture.observation(t, result)
	if got.result != want.result {
		t.Fatal("RPC reason or exit status differs from Bash")
	}
	if got.calls != want.calls {
		t.Fatal("probe command arguments differ from Bash")
	}
	if got.stdin != want.stdin {
		t.Fatal("stdin credential bytes differ from Bash")
	}
}
