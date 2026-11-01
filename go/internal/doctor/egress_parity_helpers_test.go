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

	"github.com/p2pool-starter-stack/pithead/go/internal/firewall"
)

var egressSort, _ = exec.LookPath("sort")
var egressPaste, _ = exec.LookPath("paste")

type egressFixture struct {
	TorEgress
	lan lanFixture
}

func newEgressFixture(t *testing.T) egressFixture {
	t.Helper()
	base := newLANFixture(t)
	for name, path := range map[string]string{"sort": egressSort, "paste": egressPaste} {
		if path == "" {
			t.Fatalf("%s missing", name)
		}
		if err := os.Symlink(path, filepath.Join(base.Bin, name)); err != nil {
			t.Fatal(err)
		}
	}
	writeHostTool(t, base.Bin, "sudo", egressToolLog+"[ \"$1\" = -n ] || exit 99\nshift\nexec \"$@\"\n")
	return egressFixture{TorEgress: TorEgress{OS: "Linux"}, lan: base}
}

const egressToolLog = "printf '%s\\n' \"${0##*/}\" \"$@\" >>\"${0%/*}/egress.calls\"\n"

func egressTool(t *testing.T, fixture egressFixture, name string) {
	t.Helper()
	body := egressToolLog + "case \"$*\" in\n"
	switch name {
	case "iptables":
		body += "'-S') key=all ;; '-S DOCKER-USER') key=user ;; '-S FORWARD') key=forward ;; *) exit 99 ;;\n"
	case "docker":
		body += "'ps -q --filter name=^tor$ --filter status=running') key=tor ;; *) exit 99 ;;\n"
	case "systemctl":
		body += "'is-enabled pithead-egress.service') key=enabled ;; *) exit 99 ;;\n"
	default:
		t.Fatal("unsupported egress fixture: " + name)
	}
	body += "esac\nif [ -f \"$0.$key.output\" ]; then /bin/cat \"$0.$key.output\"; fi\ncode=1\nif [ -f \"$0.$key.code\" ]; then IFS= read -r code <\"$0.$key.code\"; fi\nexit \"$code\"\n"
	writeHostTool(t, fixture.lan.Bin, name, body)
}

func egressResponse(t *testing.T, fixture egressFixture, tool, key, output string, code int) {
	t.Helper()
	lanResponse(t, fixture.lan, tool, key, output, code)
}

func egressReadback(t *testing.T, fixture egressFixture, user, forward string) {
	t.Helper()
	egressTool(t, fixture, "iptables")
	egressResponse(t, fixture, "iptables", "all", "", 0)
	egressResponse(t, fixture, "iptables", "user", user, 0)
	egressResponse(t, fixture, "iptables", "forward", forward, 0)
}

func egressCalls(t *testing.T, fixture egressFixture, clear bool) string {
	t.Helper()
	path := filepath.Join(fixture.lan.Bin, "egress.calls")
	value, err := os.ReadFile(path)
	if err != nil && !os.IsNotExist(err) {
		t.Fatal(err)
	}
	if clear && err == nil {
		if err := os.Remove(path); err != nil {
			t.Fatal(err)
		}
	}
	return string(value)
}

func runEgressBash(t *testing.T, fixture egressFixture, operation string, args ...string) hostBashResult {
	t.Helper()
	root := verificationRoot(t)
	argv := []string{filepath.Join(root, "tests", "go-parity", "doctor_egress_reference.sh"), root, operation}
	command := exec.Command(hostParityBash, append(argv, args...)...)
	appliance := "0"
	if fixture.Appliance {
		appliance = "1"
	}
	command.Env = append(hostEnvironment(t),
		"LC_ALL=C", "REFERENCE_OS="+fixture.OS, "PITHEAD_APPLIANCE="+appliance,
		"EGRESS_ENABLED="+fixture.Enabled, "EGRESS_PREFIX="+fixture.Prefix, "EGRESS_SUBNET="+fixture.Subnet,
		"EGRESS_ACTIVE="+fixture.Active, "EGRESS_RC="+os.Getenv("EGRESS_RC"))
	var stdout, stderr bytes.Buffer
	command.Stdout, command.Stderr = &stdout, &stderr
	code := 0
	if err := command.Run(); err != nil {
		var exit *exec.ExitError
		if !errors.As(err, &exit) {
			t.Fatal(err)
		}
		code = exit.ExitCode()
	}
	return hostBashResult{stdout.String(), stderr.String(), code}
}

func compareEgressReadback(t *testing.T, fixture egressFixture, code int) {
	t.Helper()
	egressCalls(t, fixture, true)
	result := runEgressBash(t, fixture, "readback")
	wantCalls := egressCalls(t, fixture, true)
	got, err := firewall.TorEnforced(fixture.TorConfig)
	if err != nil || got != code || result.code != code || result.stdout != "" || result.stderr != "" {
		t.Fatalf("readback: Go %d, %v; Bash %+v; want %d", got, err, result, code)
	}
	if calls := egressCalls(t, fixture, true); calls != wantCalls {
		t.Fatalf("readback calls: Go %q; Bash %q", calls, wantCalls)
	}
}

func compareEgressFindings(t *testing.T, fixture egressFixture) {
	t.Helper()
	egressCalls(t, fixture, true)
	result := runEgressBash(t, fixture, "findings")
	wantCalls := egressCalls(t, fixture, true)
	findings, err := fixture.Findings()
	if err != nil {
		t.Fatal(err)
	}
	assertHostFindings(t, result, findings)
	if calls := egressCalls(t, fixture, true); calls != wantCalls {
		t.Fatalf("findings calls: Go %q; Bash %q", calls, wantCalls)
	}
}

func egressRule(body string) string {
	return "-A DOCKER-USER -m comment --comment " + firewall.EgressTag + " " + body + "\n"
}

const egressDrop = "-A DOCKER-USER -m comment --comment pithead-tor-egress -s 172.28.0.0/24 -j DROP\n"
const egressForward = "-A FORWARD -j DOCKER-USER\n"

func egressFullRules(t *testing.T, fixture egressFixture) string {
	t.Helper()
	prefix, subnet := fixture.Prefix, fixture.Subnet
	if prefix == "" {
		prefix = "172.28.0"
	}
	if subnet == "" {
		subnet = "172.28.0.0/24"
	}
	args := []string{subnet, prefix + ".25"}
	for _, ip := range strings.Split(fixture.Active, "\n") {
		if ip != "" {
			args = append(args, ip)
		}
	}
	result := runEgressBash(t, fixture, "rules", args...)
	if result.code != 0 || result.stderr != "" {
		t.Fatalf("Bash rules: %+v", result)
	}
	var rules strings.Builder
	for _, rule := range strings.Split(strings.TrimRight(result.stdout, "\n"), "\n") {
		rules.WriteString(egressRule(rule))
	}
	return rules.String()
}
