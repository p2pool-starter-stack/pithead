//go:build parity

package doctor

import (
	"bytes"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

var lanJQ, _ = exec.LookPath("jq")
var lanTail, _ = exec.LookPath("tail")

type lanFixture struct {
	LANGuard
	Bin string
}

func newLANFixture(t *testing.T) lanFixture {
	t.Helper()
	base := newNetworkFixture(t)
	for name, path := range map[string]string{"jq": lanJQ, "tail": lanTail} {
		if path == "" {
			t.Fatalf("%s missing", name)
		}
		if err := os.Symlink(path, filepath.Join(base.Bin, name)); err != nil {
			t.Fatal(err)
		}
	}
	writeHostTool(t, base.Bin, "uname", "printf '%s\\n' \"${REFERENCE_OS-Linux}\"\n")
	writeHostTool(t, base.Bin, "sudo", "printf '%s\\n' \"$@\" >>\"$0.log\"\n[ \"$1\" = -n ] || exit 99\nshift\nexec \"$@\"\n")
	t.Setenv("PITHEAD_ENGINE", "docker")
	t.Setenv("LC_ALL", "C")
	return lanFixture{LANGuard: LANGuard{OS: "Linux"}, Bin: base.Bin}
}

func lanTool(t *testing.T, fixture lanFixture, name string) {
	t.Helper()
	body := "printf '%s\\n' \"$@\" >>\"$0.log\"\ncase \"$*\" in\n"
	switch name {
	case "iptables":
		body += "'-S') key=all ;; '-S PITHEAD-LAN') key=chain ;; '-S DOCKER-USER') key=user ;; '-S FORWARD') key=forward ;; *) exit 99 ;;\n"
	case "nft":
		body += "'list tables') key=all ;; '-j list table inet pithead_lan') key=table ;; *) exit 99 ;;\n"
	case "docker":
		body += "'ps -q --filter name=^monerod$ --filter status=running') key=monerod-running ;;\n'ps -q --filter name=^tari$ --filter status=running') key=tari-running ;;\n'inspect -f {{.HostConfig.RestartPolicy.Name}} monerod') key=monerod-policy ;;\n'inspect -f {{.HostConfig.RestartPolicy.Name}} tari') key=tari-policy ;;\n'inspect -f {{.State.ExitCode}} monerod') key=monerod-code ;;\n'inspect -f {{.State.ExitCode}} tari') key=tari-code ;;\n'port monerod 18081/tcp') key=rpc ;; 'port monerod 18083/tcp') key=zmq ;; 'port tari 18142/tcp') key=grpc ;; *) exit 99 ;;\n"
	case "systemctl":
		body += "'is-enabled pithead-lan-guard.service') key=enabled ;; 'is-failed --quiet pithead-lan-guard.service') key=failed ;; *) exit 99 ;;\n"
	default:
		t.Fatal("unsupported tool fixture: " + name)
	}
	body += "esac\nif [ -f \"$0.$key.output\" ]; then /bin/cat \"$0.$key.output\"; fi\ncode=1\nif [ -f \"$0.$key.code\" ]; then IFS= read -r code <\"$0.$key.code\"; fi\nexit \"$code\"\n"
	writeHostTool(t, fixture.Bin, name, body)
}

func lanResponse(t *testing.T, fixture lanFixture, tool, key, output string, code int) {
	t.Helper()
	for suffix, value := range map[string]string{".output": output, ".code": strconv.Itoa(code) + "\n"} {
		if err := os.WriteFile(filepath.Join(fixture.Bin, tool+"."+key+suffix), []byte(value), 0o600); err != nil {
			t.Fatal(err)
		}
	}
}

func lanIPTables(t *testing.T, fixture lanFixture, user string) {
	t.Helper()
	lanTool(t, fixture, "iptables")
	lanResponse(t, fixture, "iptables", "all", "", 0)
	lanResponse(t, fixture, "iptables", "chain", "-N PITHEAD-LAN\n-A PITHEAD-LAN -j DROP\n", 0)
	lanResponse(t, fixture, "iptables", "user", user, 0)
	lanResponse(t, fixture, "iptables", "forward", "-A FORWARD -j DOCKER-USER\n", 0)
}

func lanJump(port string) string {
	return "-A DOCKER-USER -p tcp -m tcp --dport " + port + " -m conntrack --ctstate NEW -m comment --comment pithead-lan-guard -j PITHEAD-LAN\n"
}

func lanCalls(t *testing.T, fixture lanFixture, clear bool) string {
	t.Helper()
	var output strings.Builder
	for _, tool := range []string{"sudo", "iptables", "nft", "docker", "systemctl"} {
		path := filepath.Join(fixture.Bin, tool+".log")
		calls, err := os.ReadFile(path)
		if err != nil && !os.IsNotExist(err) {
			t.Fatal(err)
		}
		if len(calls) != 0 {
			output.WriteString(tool + ":\n" + string(calls))
			if clear {
				if err := os.Remove(path); err != nil {
					t.Fatal(err)
				}
			}
		}
	}
	return output.String()
}

func runLANBash(t *testing.T, input lanFixture, operation string, args ...string) hostBashResult {
	t.Helper()
	root := verificationRoot(t)
	appliance := "0"
	if input.Appliance {
		appliance = "1"
	}
	binds := make([]string, 3)
	copy(binds, input.Binds)
	argv := []string{filepath.Join(root, "tests", "go-parity", "doctor_lan_reference.sh"), root, operation, input.OS, appliance}
	argv = append(argv, binds...)
	command := exec.Command(hostParityBash, append(argv, args...)...)
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

func compareLANFindings(t *testing.T, input lanFixture, operation string, ports ...string) {
	t.Helper()
	lanCalls(t, input, true)
	result := runLANBash(t, input, operation, ports...)
	wantCalls := lanCalls(t, input, true)
	var findings []Finding
	var err error
	if operation == "hold" {
		findings, err = input.Hold(ports)
	} else {
		findings, err = input.Findings()
	}
	if err != nil {
		t.Fatal(err)
	}
	assertHostFindings(t, result, findings)
	if calls := lanCalls(t, input, true); calls != wantCalls {
		t.Fatalf("LAN calls: Go %q; Bash %q", calls, wantCalls)
	}
}
