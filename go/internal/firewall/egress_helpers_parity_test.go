//go:build parity

package firewall

import (
	"bytes"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

type egressBashResult struct {
	stdout string
	stderr string
	code   int
}

var egressBash, _ = exec.LookPath("bash")

func runEgressBash(t *testing.T, operation string, arguments ...string) egressBashResult {
	t.Helper()
	if egressBash == "" {
		t.Fatal("bash not found")
	}
	root, err := filepath.Abs(filepath.Join("..", "..", ".."))
	if err != nil {
		t.Fatal(err)
	}
	bin := t.TempDir()
	for _, name := range []string{"tr", "sort", "paste"} {
		path, err := exec.LookPath(name)
		if err != nil {
			t.Fatalf("%s not found", name)
		}
		if err := os.Symlink(path, filepath.Join(bin, name)); err != nil {
			t.Fatal(err)
		}
	}
	writeEgressTool(t, bin, "uname", "printf 'Linux\\n'\n")
	writeEgressTool(t, bin, "id", "printf 'fixture\\n'\n")
	args := append([]string{filepath.Join(root, "tests", "go-parity", "doctor_egress_reference.sh"), root, operation}, arguments...)
	command := exec.Command(egressBash, args...)
	command.Env = []string{
		"PATH=" + bin,
		"TMPDIR=" + t.TempDir(),
		"LC_ALL=C",
		"REFERENCE_OS=Linux",
		"PITHEAD_APPLIANCE=0",
		"EGRESS_ENABLED=",
		"EGRESS_PREFIX=",
		"EGRESS_SUBNET=",
		"EGRESS_ACTIVE=",
	}
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
	return egressBashResult{stdout.String(), stderr.String(), code}
}

func writeEgressTool(t *testing.T, dir, name, body string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(dir, name), []byte("#!/bin/sh\n"+body), 0o755); err != nil {
		t.Fatal(err)
	}
}

func TestEgressTokeniseParity(t *testing.T) {
	lines := []string{
		"",
		"  -A  DOCKER-USER\t-s 172.28.0.26 ",
		`-m comment --comment "pithead-tor-egress"`,
		`bare" joined "tail`,
		`"escaped \\"quote\\" and \\\\ slash"`,
		`-m string --string "! -s 0.0.0.0/0 x" -j ACCEPT`,
		`one "unterminated`,
		`one "trailing\`,
	}
	for _, line := range lines {
		t.Run(line, func(t *testing.T) {
			want := runEgressBash(t, "tokenise", line)
			tokens, ok, err := egressTokenise(line)
			if err != nil {
				t.Fatal(err)
			}
			var output strings.Builder
			for _, token := range tokens {
				kind := "b:"
				if token.Quoted {
					kind = "q:"
				}
				output.WriteString(kind + token.Text + "\n")
			}
			code := 1
			if ok {
				code = 0
			}
			if want.code != code || want.stdout != output.String() || want.stderr != "" {
				t.Fatalf("Bash = exit %d, %q, %q; Go = exit %d, %q", want.code, want.stdout, want.stderr, code, output.String())
			}
		})
	}
}

func TestEgressCIDRParity(t *testing.T) {
	for _, value := range []string{
		"172.28.0.0/24", "172.28.0.25", "0.0.0.0/0", "255.255.255.255/32",
		"0172.028.000.001/024", "1.2.3.4.", "1.2.3.4..", "172.28.0.1/33", "172.28.0/24", "256.0.0.1", "1.2.3.4/", "1.2.3.4/2x",
	} {
		t.Run("valid/"+value, func(t *testing.T) {
			want := runEgressBash(t, "valid-cidr", value)
			got, err := egressValidCIDR(value)
			assertEgressBool(t, want, got, err)
		})
	}
	pairs := []struct {
		first  string
		second string
	}{
		{"172.28.0.0/24", "172.28.0.25"},
		{"172.28.0.0/25", "172.28.0.128/25"},
		{"0.0.0.0/0", "203.0.113.9/32"},
		{"10.0.0.8/32", "10.0.0.0/24"},
	}
	for _, pair := range pairs {
		name := pair.first + "/" + pair.second
		t.Run("overlaps/"+name, func(t *testing.T) {
			want := runEgressBash(t, "overlaps", pair.first, pair.second)
			got, err := egressCIDROverlaps(pair.first, pair.second)
			assertEgressBool(t, want, got, err)
		})
		t.Run("contains/"+name, func(t *testing.T) {
			want := runEgressBash(t, "contains", pair.first, pair.second)
			got, err := egressCIDRContains(pair.first, pair.second)
			assertEgressBool(t, want, got, err)
		})
	}
}

func TestEgressRuleShadowsParity(t *testing.T) {
	subnet := "172.28.0.0/24"
	lines := []string{
		"-A DOCKER-USER -j ACCEPT",
		"-A DOCKER-USER -s 172.28.0.0/25 -j ACCEPT",
		"-A DOCKER-USER -s 172.29.0.0/24 -j ACCEPT",
		"-A DOCKER-USER ! -s 172.28.0.0/16 -j ACCEPT",
		"-A DOCKER-USER ! -s 10.0.0.0/8 -j ACCEPT",
		"-A DOCKER-USER -s 172.28.0.0/24 -j DROP",
		`-A DOCKER-USER -m string --string "! -s 0.0.0.0/0 x" -s 172.29.0.0/24 -j ACCEPT`,
		`-A DOCKER-USER --comment "-s 172.28.0.0/24" -s 172.29.0.0/24 -j ACCEPT`,
		"-A DOCKER-USER -s 172.29.0.0/24 -s 172.28.0.0/24 -j ACCEPT",
		`-A DOCKER-USER "unterminated`,
		"-A DOCKER-USER -s",
		"-A DOCKER-USER -s invalid -j ACCEPT",
	}
	for _, line := range lines {
		t.Run(line, func(t *testing.T) {
			want := runEgressBash(t, "shadows", line, subnet)
			got, err := egressRuleShadows(line, subnet)
			assertEgressBool(t, want, got, err)
		})
	}
}

func TestEgressCanonicalParity(t *testing.T) {
	lines := []string{
		"",
		"-A DOCKER-USER -s 172.28.0.26/32 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT",
		`--comment "pithead-tor-egress" -j DROP -s 172.28.0.0/24`,
		"-j ACCEPT -A DOCKER-USER",
		"-A DOCKER-USER -s",
		`"-A" DOCKER-USER`,
	}
	for _, line := range lines {
		t.Run(line, func(t *testing.T) {
			want := runEgressBash(t, "canonical", line)
			got, ok, err := egressCanonical(line)
			if err != nil {
				t.Fatal(err)
			}
			code := 1
			output := ""
			if ok {
				code = 0
				if got != "" {
					output = got + "\n"
				}
			}
			if want.code != code || want.stdout != output || want.stderr != "" {
				t.Fatalf("Bash = exit %d, %q, %q; Go = exit %d, %q", want.code, want.stdout, want.stderr, code, output)
			}
		})
	}
}

func TestEgressSyncAcceptParity(t *testing.T) {
	ip := "172.28.0.26"
	lines := []string{
		"-A DOCKER-USER -s 172.28.0.26 -m comment --comment pithead-tor-egress -j ACCEPT",
		"-j ACCEPT --comment pithead-tor-egress -m comment -s 172.28.0.26/32 -A DOCKER-USER",
		`--comment "" --comment pithead-tor-egress -j ACCEPT -m comment -s 172.28.0.26 -A DOCKER-USER`,
		`-A DOCKER-USER -s 172.28.0.26 -m comment --comment "pithead-tor-egress" -j ACCEPT`,
		"-A DOCKER-USER -s 172.28.0.27 -m comment --comment pithead-tor-egress -j ACCEPT",
		"-A DOCKER-USER -s 172.28.0.26 -j ACCEPT",
		"-A DOCKER-USER -s 172.28.0.26 -m comment --comment pithead-tor-egress -j ACCEPT -j ACCEPT",
		`-A DOCKER-USER "unterminated`,
	}
	for _, line := range lines {
		t.Run(line, func(t *testing.T) {
			want := runEgressBash(t, "sync-accept", line, ip)
			got, err := egressSyncAccept(line, ip)
			assertEgressBool(t, want, got, err)
		})
	}
}

func assertEgressBool(t *testing.T, want egressBashResult, got bool, err error) {
	t.Helper()
	if err != nil {
		t.Fatal(err)
	}
	code := 1
	if got {
		code = 0
	}
	if want.code != code || want.stdout != "" || want.stderr != "" {
		t.Fatalf("Bash = exit %d, %q, %q; Go = exit %d", want.code, want.stdout, want.stderr, code)
	}
}
