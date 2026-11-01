//go:build parity

package nodeprobe

import (
	"bytes"
	"encoding/binary"
	"encoding/hex"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"testing"
)

type zmqFixture struct {
	dir string
}

type zmqBashResult struct {
	stdout string
	stderr string
	code   int
}

func newZMQFixture(t *testing.T) zmqFixture {
	t.Helper()
	if parityBash == "" {
		t.Fatal("Bash is required")
	}
	fixture := zmqFixture{t.TempDir()}
	writeExecutable(t, fixture.dir, "timeout", `#!/bin/sh
dir=${0%/*}
/bin/cat "$dir/reply.value"
exit "$(/bin/cat "$dir/exit.code")"
`)
	t.Setenv("PATH", fixture.dir)
	return fixture
}

func (fixture zmqFixture) reference(t *testing.T, operation, value string, exitCode int) zmqBashResult {
	t.Helper()
	argument := value
	if operation == "classify" {
		for name, data := range map[string]string{"reply.value": value, "exit.code": strconv.Itoa(exitCode)} {
			if err := os.WriteFile(filepath.Join(fixture.dir, name), []byte(data), 0o600); err != nil {
				t.Fatal(err)
			}
		}
		argument = ""
	}
	_, file, _, _ := runtime.Caller(0)
	root := filepath.Clean(filepath.Join(filepath.Dir(file), "..", "..", ".."))
	cmd := exec.Command(parityBash, filepath.Join(root, "tests", "go-parity", "node_zmq_reference.sh"), root, operation, argument)
	cmd.Env = []string{"PATH=" + fixture.dir, "LC_ALL=C", "TMPDIR=" + t.TempDir()}
	var stdout, stderr bytes.Buffer
	cmd.Stdout, cmd.Stderr = &stdout, &stderr
	code := 0
	if err := cmd.Run(); err != nil {
		if status, ok := err.(*exec.ExitError); ok {
			code = status.ExitCode()
		} else {
			t.Fatal("Bash ZMTP oracle failed to launch")
		}
	}
	return zmqBashResult{stdout.String(), stderr.String(), code}
}

func compareZMQ(t *testing.T, operation, value string, exitCode int) {
	t.Helper()
	fixture := newZMQFixture(t)
	want := fixture.reference(t, operation, value, exitCode)
	if want.code != 0 || want.stderr != "" {
		t.Fatal("Bash ZMTP oracle failed or exposed a diagnostic")
	}
	var result string
	if operation == "classify" {
		reason, err := ClassifyZMQPublisher(value, exitCode)
		if err != nil {
			t.Fatal(err)
		}
		result = "1\n" + reason + "\n"
		if reason == "ok" {
			result = "0\nok\n"
		}
	} else {
		validate := ZMQGreetingOK
		if operation == "ready" {
			validate = ZMQReadyIsPublisher
		}
		ok, err := validate(value)
		if err != nil {
			t.Fatal(err)
		}
		result = "1\n"
		if ok {
			result = "0\n"
		}
	}
	if result != want.stdout {
		t.Fatal("ZMTP predicate, reason or exit status differs from Bash")
	}
}

func zmqParityGreeting() []byte {
	value := make([]byte, 64)
	value[0], value[9], value[10], value[11] = 0xff, 0x7f, 3, 1
	copy(value[12:], "NULL")
	return value
}

func zmqParityProperty(key, value string) []byte {
	property := append([]byte{byte(len(key))}, key...)
	property = binary.BigEndian.AppendUint32(property, uint32(len(value)))
	return append(property, value...)
}

func zmqParityFrame(properties ...[]byte) string {
	body := []byte{5, 'R', 'E', 'A', 'D', 'Y'}
	for _, property := range properties {
		body = append(body, property...)
	}
	return hex.EncodeToString(append([]byte{4, byte(len(body))}, body...))
}
