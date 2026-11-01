package doctor

import (
	"errors"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"testing"
)

func TestTorStateSaturatedStages(t *testing.T) {
	tests := []struct {
		name      string
		env       map[string]string
		want      bool
		wantCalls int
	}{
		{"saturated", nil, true, 5},
		{"missing", map[string]string{"TOR_FILE": "1"}, false, 1},
		{"symlink", map[string]string{"TOR_LINK": "1"}, false, 2},
		{"abandoned", map[string]string{"TOR_ABANDONED": "1"}, false, 3},
		{"total", map[string]string{"TOR_TOTAL": "1"}, false, 4},
		{"bins", map[string]string{"TOR_BINS": "0"}, false, 5},
		{"bin-read-error", map[string]string{"TOR_BINS": "2"}, true, 5},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			bin := t.TempDir()
			trace := filepath.Join(t.TempDir(), "trace")
			t.Setenv("PATH", bin)
			t.Setenv("TOR_TRACE", trace)
			for name, value := range test.env {
				t.Setenv(name, value)
			}
			torHistoryTool(t, bin, "sudo", `
printf '%s\n' "$*" >> "$TOR_TRACE"
case "$*" in
  "test -f "*) exit "${TOR_FILE:-0}" ;;
  "test ! -L "*) exit "${TOR_LINK:-0}" ;;
  "grep -qx CircuitBuildAbandonedCount 1000 "*) exit "${TOR_ABANDONED:-0}" ;;
  "grep -qx TotalBuildTimes 1000 "*) exit "${TOR_TOTAL:-0}" ;;
  "grep -q ^CircuitBuildTimeBin  "*) exit "${TOR_BINS:-1}" ;;
esac
exit 70`)
			got, err := TorStateSaturated("/tor/state")
			if err != nil || got != test.want {
				t.Fatalf("TorStateSaturated() = %v, %v; want %v", got, err, test.want)
			}
			lines := strings.Split(strings.TrimSpace(torHistoryRead(t, trace)), "\n")
			if len(lines) != test.wantCalls {
				t.Fatalf("calls = %#v; want %d", lines, test.wantCalls)
			}
		})
	}
}

func TestTorStateSaturatedArgumentsAndUnsupportedInputs(t *testing.T) {
	bin := t.TempDir()
	trace := filepath.Join(t.TempDir(), "trace")
	t.Setenv("PATH", bin)
	t.Setenv("TOR_TRACE", trace)
	torHistoryTool(t, bin, "sudo", `printf '%s\n' "$*" >> "$TOR_TRACE"; exit 0`)
	got, err := TorStateSaturated("/data/state file")
	if err != nil || got {
		t.Fatalf("TorStateSaturated() = %v, %v", got, err)
	}
	want := strings.Join([]string{
		"test -f /data/state file",
		"test ! -L /data/state file",
		"grep -qx CircuitBuildAbandonedCount 1000 /data/state file",
		"grep -qx TotalBuildTimes 1000 /data/state file",
		"grep -q ^CircuitBuildTimeBin  /data/state file",
	}, "\n") + "\n"
	if trace := torHistoryRead(t, trace); trace != want {
		t.Fatalf("trace = %q; want %q", trace, want)
	}
	if _, err := TorStateSaturated("bad\x00state"); !errors.Is(err, ErrUnsupportedProbeInput) {
		t.Fatalf("NUL error = %v", err)
	}
	if err := os.WriteFile(filepath.Join(bin, "sudo"), []byte("exit 0\n"), 0o700); err != nil {
		t.Fatal(err)
	}
	if _, err := TorStateSaturated("/tor/state"); !errors.Is(err, ErrUnsupportedProbeInput) {
		t.Fatalf("launcher error = %v", err)
	}
}

func TestTorRecoveryEgressDown(t *testing.T) {
	tests := []struct {
		name, first, second, prefix string
		want, invalid               bool
		calls                       int
	}{
		{"first-up", "0", "1", "10.2.0", false, false, 1},
		{"second-up", "1", "0", "", false, false, 2},
		{"both-down", "1", "22", "10.3.0\n", true, false, 2},
		{"invalid-prefix", "1", "1", "bad\x00", false, true, 0},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			bin := t.TempDir()
			trace := filepath.Join(t.TempDir(), "trace")
			t.Setenv("PATH", bin)
			t.Setenv("TOR_TRACE", trace)
			t.Setenv("TOR_FIRST", test.first)
			t.Setenv("TOR_SECOND", test.second)
			torHistoryTool(t, bin, "curl", `
printf 'CALL\n' >> "$TOR_TRACE"
for value do printf '<%s>\n' "$value" >> "$TOR_TRACE"; done
case "$*" in
  *google.com*) exit "$TOR_FIRST" ;;
  *) exit "$TOR_SECOND" ;;
esac`)
			got, err := TorRecoveryEgressDown(test.prefix)
			if test.invalid {
				if !errors.Is(err, ErrUnsupportedProbeInput) {
					t.Fatalf("error = %v", err)
				}
				return
			}
			if err != nil || got != test.want {
				t.Fatalf("TorRecoveryEgressDown() = %v, %v; want %v", got, err, test.want)
			}
			calls := strings.Count(torHistoryRead(t, trace), "CALL\n")
			if calls != test.calls {
				t.Fatalf("calls = %d; want %d", calls, test.calls)
			}
			assertTorCurlCalls(t, trace, test.prefix, test.calls)
		})
	}
}

func TestTorRecoveryEgressToolGates(t *testing.T) {
	bin := t.TempDir()
	t.Setenv("PATH", bin)
	if down, err := TorRecoveryEgressDown("bad\x00"); err != nil || down {
		t.Fatalf("missing curl = %v, %v", down, err)
	}
	if err := os.WriteFile(filepath.Join(bin, "curl"), []byte("exit 1\n"), 0o700); err != nil {
		t.Fatal(err)
	}
	if _, err := TorRecoveryEgressDown(""); !errors.Is(err, ErrUnsupportedProbeInput) {
		t.Fatalf("launcher error = %v", err)
	}
}

func TestTorCircuitHistoryFindingsAndGates(t *testing.T) {
	tests := []struct {
		name       string
		history    TorCircuitHistory
		env        map[string]string
		wantStatus string
		wantText   string
		wantError  bool
	}{
		{"stopped", TorCircuitHistory{Mount: "bad\x00", MountAvailable: true, Prefix: "bad\x00"}, map[string]string{"TOR_RUNNING": "0"}, "", "", false},
		{"sudo-refused", TorCircuitHistory{Mount: "bad\x00", MountAvailable: true}, map[string]string{"TOR_UID": "1000", "TOR_GATE": "1"}, "", "", false},
		{"mount-unavailable", TorCircuitHistory{Mount: "bad\x00"}, nil, "", "", false},
		{"invalid-mount", TorCircuitHistory{Mount: "bad\x00", MountAvailable: true}, nil, "", "", true},
		{"not-saturated", TorCircuitHistory{Mount: "/tor", MountAvailable: true, Prefix: "bad\x00"}, map[string]string{"TOR_ABANDONED": "1"}, "", "", false},
		{"invalid-prefix", TorCircuitHistory{Mount: "/tor", MountAvailable: true, Prefix: "bad\x00"}, nil, "", "", true},
		{"egress-up", TorCircuitHistory{Mount: "/tor", MountAvailable: true}, map[string]string{"TOR_FIRST": "0"}, "", "", false},
		{"diy", TorCircuitHistory{Mount: "/tor\n", MountAvailable: true, Prefix: "10.8.0\n"}, map[string]string{"TOR_UID": "1000", "TOR_GATE": "0"}, "fail", "Run './pithead tor-recover check'", false},
		{"appliance", TorCircuitHistory{Mount: "/tor", MountAvailable: true, Appliance: true}, nil, "fail", "requests host-gated state recovery", false},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			bin := torHistoryFixture(t)
			t.Setenv("PATH", bin)
			for name, value := range test.env {
				t.Setenv(name, value)
			}
			findings, err := test.history.Findings()
			if test.wantError {
				if !errors.Is(err, ErrUnsupportedProbeInput) {
					t.Fatalf("error = %v", err)
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			if test.wantStatus == "" {
				if findings != nil {
					t.Fatalf("findings = %#v", findings)
				}
				return
			}
			if len(findings) != 1 || findings[0].ID != "tor-circuit-history" || findings[0].Status != test.wantStatus || !strings.Contains(findings[0].Message, test.wantText) {
				t.Fatalf("findings = %#v", findings)
			}
		})
	}
}

func TestTorHistoryPrivilegeGate(t *testing.T) {
	tests := []struct {
		name, id, sudo string
		idPresent      bool
		want           bool
		wantError      bool
	}{
		{"root", "printf '0\\n'; exit 0", "exit 70", true, true, false},
		{"nonroot-allowed", "printf '1000\\n'; exit 0", `[ "$*" = "-n true" ]; exit $?`, true, true, false},
		{"nonroot-refused", "printf '1000\\n'; exit 0", "exit 1", true, false, false},
		{"id-failed-with-root-output", "printf '0\\n'; exit 1", "exit 70", true, true, false},
		{"missing-id", "", "exit 0", false, false, true},
		{"ambiguous-id", "printf '0\\000x'", "exit 0", true, false, true},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			bin := t.TempDir()
			t.Setenv("PATH", bin)
			if test.idPresent {
				torHistoryTool(t, bin, "id", test.id)
			}
			torHistoryTool(t, bin, "sudo", test.sudo)
			got, err := torHistorySudoAllowed()
			if test.wantError {
				if !errors.Is(err, ErrUnsupportedProbeInput) {
					t.Fatalf("error = %v", err)
				}
				return
			}
			if err != nil || got != test.want {
				t.Fatalf("torHistorySudoAllowed() = %v, %v; want %v", got, err, test.want)
			}
		})
	}
}

func torHistoryFixture(t *testing.T) string {
	t.Helper()
	bin := t.TempDir()
	torHistoryTool(t, bin, "docker", `[ "${TOR_RUNNING:-1}" = 1 ] && printf 'cid\n'; exit 0`)
	torHistoryTool(t, bin, "id", `printf '%s\n' "${TOR_UID:-0}"; exit "${TOR_ID_CODE:-0}"`)
	torHistoryTool(t, bin, "sudo", `
if [ "$*" = "-n true" ]; then exit "${TOR_GATE:-0}"; fi
case "$*" in
  "test -f "*) exit "${TOR_FILE:-0}" ;;
  "test ! -L "*) exit "${TOR_LINK:-0}" ;;
  "grep -qx CircuitBuildAbandonedCount 1000 "*) exit "${TOR_ABANDONED:-0}" ;;
  "grep -qx TotalBuildTimes 1000 "*) exit "${TOR_TOTAL:-0}" ;;
  "grep -q ^CircuitBuildTimeBin  "*) exit "${TOR_BINS:-1}" ;;
esac
exit 70`)
	torHistoryTool(t, bin, "curl", `
case "$*" in
  *google.com*) exit "${TOR_FIRST:-1}" ;;
  *) exit "${TOR_SECOND:-1}" ;;
esac`)
	return bin
}

func assertTorCurlCalls(t *testing.T, path, prefix string, count int) {
	t.Helper()
	if prefix == "" {
		prefix = "172.28.0"
	}
	prefix = strings.TrimRight(prefix, "\n")
	parts := strings.Split(torHistoryRead(t, path), "CALL\n")[1:]
	authPattern := regexp.MustCompile(`^<tor-recover-` + strconv.Itoa(os.Getpid()) + `-[0-9]+-[0-9]+:isolate>$`)
	for index := 0; index < count; index++ {
		args := strings.Split(strings.TrimSpace(parts[index]), "\n")
		want := []string{"<-sS>", "<--max-time>", "<15>", "<--proxy-user>", "", "<--socks5-hostname>", "<" + prefix + ".25:9050>", "<-o>", "</dev/null>", "<" + torRecoveryTargets[index] + ">"}
		if len(args) != len(want) || !authPattern.MatchString(args[4]) {
			t.Fatalf("curl args = %#v", args)
		}
		args[4] = ""
		if strings.Join(args, "\n") != strings.Join(want, "\n") {
			t.Fatalf("curl args = %#v; want %#v", args, want)
		}
	}
}

func torHistoryTool(t *testing.T, dir, name, body string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(dir, name), []byte("#!/bin/sh\n"+body+"\n"), 0o700); err != nil {
		t.Fatal(err)
	}
}

func torHistoryRead(t *testing.T, path string) string {
	t.Helper()
	value, err := os.ReadFile(path)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return ""
		}
		t.Fatal(err)
	}
	return string(value)
}
