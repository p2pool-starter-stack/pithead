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

type networkFixture struct {
	StratumExposure
	Prefix string
	Dir    string
	Bin    string
}

func newNetworkFixture(t *testing.T) networkFixture {
	t.Helper()
	bin, dir := t.TempDir(), t.TempDir()
	for name, path := range map[string]string{"grep": controlToolPaths["grep"], "tr": controlToolPaths["tr"]} {
		if path == "" {
			t.Fatalf("%s unavailable", name)
		}
		if err := os.Symlink(path, filepath.Join(bin, name)); err != nil {
			t.Fatal(err)
		}
	}
	writeHostTool(t, bin, "uname", "printf 'Linux\\n'\n")
	writeHostTool(t, bin, "id", "printf 'fixture\\n'\n")
	t.Setenv("PATH", bin)
	return networkFixture{Dir: dir, Bin: bin}
}

func networkToolFixture(t *testing.T, fixture networkFixture, name, output string, code int) {
	t.Helper()
	path := filepath.Join(fixture.Bin, name)
	if err := os.WriteFile(path+".output", []byte(output), 0o600); err != nil {
		t.Fatal(err)
	}
	body := "printf '%s\\n' \"$@\" >>\"$0.log\"\n/bin/cat \"$0.output\"\nprintf 'suppressed diagnostics\\n' >&2\nexit " + strconv.Itoa(code) + "\n"
	writeHostTool(t, fixture.Bin, name, body)
}

func networkContainers(t *testing.T, fixture networkFixture, names ...string) {
	t.Helper()
	writeHostTool(t, fixture.Bin, "docker", "printf '%s\\n' \"$@\" >>\"$0.log\"\n/bin/cat \"$0.$4\" 2>/dev/null\nexit 0\n")
	for _, name := range names {
		if err := os.WriteFile(filepath.Join(fixture.Bin, "docker.name=^"+name+"$"), []byte("cid\n"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
}

func runNetworkBash(t *testing.T, input networkFixture, operation string) hostBashResult {
	t.Helper()
	root := verificationRoot(t)
	appliance := "0"
	if input.Appliance {
		appliance = "1"
	}
	if input.EnvPresent {
		verificationFile(t, filepath.Join(input.Dir, ".env"))
	} else if err := os.Remove(filepath.Join(input.Dir, ".env")); err != nil && !os.IsNotExist(err) {
		t.Fatal(err)
	}
	command := exec.Command(hostParityBash, filepath.Join(root, "tests", "go-parity", "doctor_network_reference.sh"),
		root, operation, input.Dir, appliance, input.Bind, input.Port, input.EnvBind, input.EnvPort, input.Password, input.TLS, input.Prefix)
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

func networkCalls(t *testing.T, fixture networkFixture, clear bool) string {
	t.Helper()
	var result bytes.Buffer
	for _, name := range []string{"docker", "ip", "ss", "curl"} {
		path := filepath.Join(fixture.Bin, name+".log")
		calls, err := os.ReadFile(path)
		if err != nil && !os.IsNotExist(err) {
			t.Fatal(err)
		}
		if len(calls) != 0 {
			result.WriteString(name + ":\n" + string(calls))
			if clear {
				if err := os.Remove(path); err != nil {
					t.Fatal(err)
				}
			}
		}
	}
	return result.String()
}

func compareNetwork(t *testing.T, input networkFixture, operation string) {
	t.Helper()
	networkCalls(t, input, true)
	result := runNetworkBash(t, input, operation)
	wantCalls := networkCalls(t, input, true)
	var findings []Finding
	var err error
	switch operation {
	case "exposure":
		findings, err = input.Findings()
	case "listening":
		var finding Finding
		finding, err = (StratumListening{input.Stratum, input.Appliance}).Finding()
		findings = []Finding{finding}
	case "tor":
		var finding Finding
		finding, err = TorRunning(input.Appliance)
		findings = []Finding{finding}
	case "clearnet":
		var finding Finding
		finding, err = (TorClearnetEgress{input.Prefix, input.Appliance}).Finding()
		findings = []Finding{finding}
	default:
		t.Fatal("unsupported comparison: " + operation)
	}
	if err != nil {
		t.Fatal(err)
	}
	assertHostFindings(t, result, findings)
	if calls := networkCalls(t, input, true); calls != wantCalls {
		t.Fatalf("tool calls: Go %q; Bash %q", calls, wantCalls)
	}
}
