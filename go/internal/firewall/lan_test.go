package firewall

import (
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func TestConstants(t *testing.T) {
	if LANTag != "pithead-lan-guard" || LANChain != "PITHEAD-LAN" || LANTable != "pithead_lan" || EgressTag != "pithead-tor-egress" {
		t.Fatal("firewall constants changed")
	}
}

func TestEngine(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("PATH", dir)
	if got, err := Engine(); err != nil || got != "docker" {
		t.Fatalf("missing tools = %q, %v", got, err)
	}
	writeTool(t, dir, "podman", "exit 0")
	if got, err := Engine(); err != nil || got != "podman" {
		t.Fatalf("podman = %q, %v", got, err)
	}
	writeTool(t, dir, "docker", "exit 0")
	if got, err := Engine(); err != nil || got != "docker" {
		t.Fatalf("both = %q, %v", got, err)
	}
	t.Setenv("PITHEAD_ENGINE", "podman")
	t.Setenv("PATH", ".")
	if got, err := Engine(); err != nil || got != "podman" {
		t.Fatalf("override = %q, %v", got, err)
	}
	t.Setenv("PITHEAD_ENGINE", "invalid")
	if got, err := Engine(); got != "" || !errors.Is(err, ErrUnsupportedInput) {
		t.Fatalf("relative path = %q, %v", got, err)
	}
}

func TestLANEnforcedInput(t *testing.T) {
	for _, port := range []string{"", "018081", "-1", "65536", "18081|.*", "18\x00081"} {
		if rc, err := LANEnforced([]string{port}); rc != 0 || !errors.Is(err, ErrUnsupportedInput) {
			t.Fatalf("port %q = %d, %v", port, rc, err)
		}
	}
}

func TestIPTablesReturnCodes(t *testing.T) {
	goodChain := "-N " + LANChain + "\n-A " + LANChain + " -s 10.0.0.0/8 -j RETURN\n-A " + LANChain + " -j DROP"
	jump1 := "-A DOCKER-USER -p tcp --dport 18081 -m comment --comment " + LANTag + " -j " + LANChain
	jump2 := "-A DOCKER-USER -p tcp --dport 18083 -m comment --comment " + LANTag + " -j " + LANChain
	tests := []struct {
		name    string
		chain   string
		docker  string
		forward string
		fails   string
		want    int
	}{
		{"success", goodChain, jump1 + "\n" + jump2, "-A FORWARD -j DOCKER-USER", "", 0},
		{"chain absent", "", jump1 + "\n" + jump2, "-A FORWARD -j DOCKER-USER", "chain", 1},
		{"drop not terminal", goodChain + "\n-A " + LANChain + " -j RETURN", jump1 + "\n" + jump2, "-A FORWARD -j DOCKER-USER", "", 1},
		{"jump absent", goodChain, jump1, "-A FORWARD -j DOCKER-USER", "", 1},
		{"foreign accept first", goodChain, "-A DOCKER-USER -j ACCEPT\n" + jump1 + "\n" + jump2, "-A FORWARD -j DOCKER-USER", "", 5},
		{"foreign return between", goodChain, jump1 + "\n-A DOCKER-USER -j RETURN\n" + jump2, "-A FORWARD -j DOCKER-USER", "", 5},
		{"egress accept ignored", goodChain, "-A DOCKER-USER -m comment --comment " + EgressTag + " -j ACCEPT\n" + jump1 + "\n" + jump2, "-A FORWARD -j DOCKER-USER", "", 0},
		{"forward absent", goodChain, jump1 + "\n" + jump2, "-A FORWARD -j OTHER", "", 4},
		{"forward unreadable", goodChain, jump1 + "\n" + jump2, "partial", "forward", 4},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			dir, log := iptablesTools(t, test.chain, test.docker, test.forward, test.fails)
			t.Setenv("PATH", dir)
			rc, err := LANEnforced([]string{"18081", "18083"})
			if err != nil || rc != test.want {
				t.Fatalf("LANEnforced() = %d, %v; want %d", rc, err, test.want)
			}
			calls := readLines(t, log)
			if len(calls) == 0 || calls[0] != "-n iptables -S" {
				t.Fatalf("calls = %#v", calls)
			}
			if test.name == "success" {
				want := []string{"-n iptables -S", "-n iptables -S " + LANChain, "-n iptables -S DOCKER-USER", "-n iptables -S FORWARD"}
				if !reflect.DeepEqual(calls, want) {
					t.Fatalf("calls = %#v", calls)
				}
			}
		})
	}
}

func TestIPTablesAvailabilityAndUnsupportedOutput(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("PATH", dir)
	if rc, err := LANEnforced(nil); err != nil || rc != 2 {
		t.Fatalf("missing iptables = %d, %v", rc, err)
	}
	writeTool(t, dir, "iptables", "exit 0")
	if rc, err := LANEnforced(nil); err != nil || rc != 3 {
		t.Fatalf("missing sudo = %d, %v", rc, err)
	}
	writeFile(t, filepath.Join(dir, "sudo"), "exit 0\n", 0o700)
	if rc, err := LANEnforced(nil); rc != 0 || !errors.Is(err, ErrUnsupportedInput) {
		t.Fatalf("no shebang = %d, %v", rc, err)
	}
	dir = t.TempDir()
	writeTool(t, dir, "docker", "exit 0")
	writeFile(t, filepath.Join(dir, "iptables"), "exit 0\n", 0o700)
	t.Setenv("PATH", dir)
	if rc, err := LANEnforced(nil); rc != 0 || !errors.Is(err, ErrUnsupportedInput) {
		t.Fatalf("backend no shebang = %d, %v", rc, err)
	}
	dir, _ = iptablesTools(t, "-A "+LANChain+" -j DROP\\0000", "", "", "")
	t.Setenv("PATH", dir)
	if rc, err := LANEnforced(nil); rc != 0 || !errors.Is(err, ErrUnsupportedInput) {
		t.Fatalf("NUL output = %d, %v", rc, err)
	}
}

func TestIPTablesFailedOutputFallback(t *testing.T) {
	dir := t.TempDir()
	writeTool(t, dir, "docker", "exit 0")
	writeTool(t, dir, "iptables", "exit 0")
	writeTool(t, dir, "sudo", `printf 'partial\000bad'
exit 1`)
	t.Setenv("PATH", dir)
	if rc, err := LANEnforced(nil); rc != 0 || !errors.Is(err, ErrUnsupportedInput) {
		t.Fatalf("failed NUL read = %d, %v", rc, err)
	}
	dir = t.TempDir()
	writeTool(t, dir, "docker", "exit 0")
	writeTool(t, dir, "iptables", "exit 0")
	writeTool(t, dir, "sudo", "printf 'partial'; exit 1")
	t.Setenv("PATH", dir)
	if rc, err := LANEnforced(nil); err != nil || rc != 3 {
		t.Fatalf("failed ordinary read = %d, %v", rc, err)
	}
}

func TestIPTablesParserToolFallback(t *testing.T) {
	chain := "-A " + LANChain + " -j DROP"
	jump := "-A DOCKER-USER -p tcp --dport 18081 -m comment --comment " + LANTag + " -j " + LANChain
	for _, test := range []struct {
		name    string
		ports   []string
		missing string
		docker  string
		unsafe  bool
	}{
		{"tail after chain", nil, "tail", "", false},
		{"unsafe tail", nil, "tail", "", true},
		{"grep before port match", []string{"18081"}, "grep", jump, false},
		{"unsafe grep", []string{"18081"}, "grep", jump, true},
		{"grep after forward", nil, "grep", "", false},
	} {
		t.Run(test.name, func(t *testing.T) {
			dir, _ := iptablesTools(t, chain, test.docker, "-A FORWARD -j DOCKER-USER", "")
			path := filepath.Join(dir, test.missing)
			if test.unsafe {
				writeFile(t, path, "exit 0\n", 0o700)
			} else if err := os.Remove(path); err != nil {
				t.Fatal(err)
			}
			t.Setenv("PATH", dir)
			if rc, err := LANEnforced(test.ports); rc != 0 || !errors.Is(err, ErrUnsupportedInput) {
				t.Fatalf("LANEnforced() = %d, %v", rc, err)
			}
		})
	}
}

func TestNFTAvailabilityAndReads(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("PITHEAD_ENGINE", "podman")
	t.Setenv("PATH", dir)
	if rc, err := LANEnforced(nil); err != nil || rc != 2 {
		t.Fatalf("missing nft = %d, %v", rc, err)
	}
	writeTool(t, dir, "nft", "exit 0")
	if rc, err := LANEnforced(nil); err != nil || rc != 3 {
		t.Fatalf("missing jq = %d, %v", rc, err)
	}
	writeTool(t, dir, "jq", "exit 0")
	if rc, err := LANEnforced(nil); err != nil || rc != 3 {
		t.Fatalf("missing sudo = %d, %v", rc, err)
	}

	for _, test := range []struct {
		name  string
		fails string
		want  int
	}{
		{"initial", "initial", 3},
		{"table", "table", 1},
	} {
		t.Run(test.name, func(t *testing.T) {
			dir, _ := nftTools(t, `{}`, test.fails)
			t.Setenv("PATH", dir)
			rc, err := LANEnforced(nil)
			if err != nil || rc != test.want {
				t.Fatalf("LANEnforced() = %d, %v", rc, err)
			}
		})
	}
}

func TestNFTValidation(t *testing.T) {
	good := nftJSON("guard", `[{"match":{"right":18081}},{"match":{"right":18083}},{"drop":null}]`)
	tests := []struct {
		name  string
		json  string
		ports []string
		want  int
		bad   bool
	}{
		{"success", good, []string{"18081", "18083"}, 0, false},
		{"chain order independent", `{"nftables":[{"rule":{"chain":"guard","expr":[{"match":{"right":18081}},{"drop":null}]}},{"chain":{"name":"guard","hook":"forward"}}]}`, []string{"18081"}, 0, false},
		{"wrong hook", strings.Replace(good, `"forward"`, `"input"`, 1), []string{"18081"}, 1, false},
		{"no drop", strings.Replace(good, `{"drop":null}`, `{"accept":null}`, 1), []string{"18081"}, 1, false},
		{"missing port", good, []string{"18081", "18142"}, 1, false},
		{"split rules", `{"nftables":[{"chain":{"name":"guard","hook":"forward"}},{"rule":{"chain":"guard","expr":[{"match":{"right":18081}},{"drop":null}]}},{"rule":{"chain":"guard","expr":[{"match":{"right":18083}},{"drop":null}]}}]}`, []string{"18081", "18083"}, 1, false},
		{"digit boundary", nftJSON("guard", `[{"match":{"right":1180812}},{"drop":null}]`), []string{"18081"}, 1, false},
		{"empty ports", nftJSON("guard", `[{"drop":null}]`), nil, 0, false},
		{"exponent port", nftJSON("guard", `[{"match":{"right":1.8081e4}},{"drop":null}]`), []string{"18081"}, 0, false},
		{"decimal port", nftJSON("guard", `[{"match":{"right":18081.0}},{"drop":null}]`), []string{"18081"}, 0, false},
		{"malformed", `{`, nil, 0, true},
		{"unsafe shape", `{"nftables":[1]}`, nil, 0, true},
		{"later malformed rule", `{"nftables":[{"chain":{"name":"guard","hook":"forward"}},{"rule":{"chain":"guard","expr":[{"match":{"right":18081}},{"drop":null}]}},{"rule":{"chain":"guard","expr":[1]}}]}`, []string{"18081"}, 0, true},
		{"unsafe large counter", nftJSON("guard", `[{"counter":{"packets":9007199254740993}},{"match":{"right":18081}},{"drop":null}]`), []string{"18081"}, 0, true},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			dir, log := nftTools(t, test.json, "")
			t.Setenv("PITHEAD_ENGINE", "podman")
			t.Setenv("PATH", dir)
			rc, err := LANEnforced(test.ports)
			if test.bad {
				if rc != 0 || !errors.Is(err, ErrUnsupportedInput) {
					t.Fatalf("LANEnforced() = %d, %v", rc, err)
				}
			} else if err != nil || rc != test.want {
				t.Fatalf("LANEnforced() = %d, %v; want %d", rc, err, test.want)
			}
			if got := readLines(t, log); !reflect.DeepEqual(got, []string{"-n nft list tables", "-n nft -j list table inet " + LANTable}) {
				t.Fatalf("calls = %#v", got)
			}
		})
	}
}

func nftJSON(chain, expr string) string {
	return `{"nftables":[{"chain":{"name":"` + chain + `","hook":"forward"}},{"rule":{"chain":"` + chain + `","expr":` + expr + `}}]}`
}

func iptablesTools(t *testing.T, chain, dockerUser, forward, fails string) (string, string) {
	t.Helper()
	dir := t.TempDir()
	log := filepath.Join(dir, "calls")
	writeTool(t, dir, "docker", "exit 0")
	writeTool(t, dir, "iptables", "exit 0")
	writeTool(t, dir, "tail", "exit 0")
	writeTool(t, dir, "grep", "exit 0")
	body := "printf '%s\\n' \"$*\" >>'" + log + "'\ncase \"$*\" in\n"
	body += "'-n iptables -S') [ '" + fails + "' = initial ] && { printf 'partial'; exit 1; }; true ;;\n"
	body += "'-n iptables -S " + LANChain + "') [ '" + fails + "' = chain ] && exit 1; printf '%b\\n' '" + chain + "' ;;\n"
	body += "'-n iptables -S DOCKER-USER') [ '" + fails + "' = docker ] && exit 1; printf '%b\\n' '" + dockerUser + "' ;;\n"
	body += "'-n iptables -S FORWARD') [ '" + fails + "' = forward ] && { printf 'partial'; exit 1; }; printf '%b\\n' '" + forward + "' ;;\nesac"
	writeTool(t, dir, "sudo", body)
	return dir, log
}

func nftTools(t *testing.T, document, fails string) (string, string) {
	t.Helper()
	dir := t.TempDir()
	log := filepath.Join(dir, "calls")
	writeTool(t, dir, "nft", "exit 0")
	writeTool(t, dir, "jq", "exit 0")
	body := "printf '%s\\n' \"$*\" >>'" + log + "'\ncase \"$*\" in\n"
	body += "'-n nft list tables') [ '" + fails + "' = initial ] && { printf 'partial'; exit 1; }; true ;;\n"
	body += "'-n nft -j list table inet " + LANTable + "') [ '" + fails + "' = table ] && { printf 'partial'; exit 1; }; printf '%s\\n' '" + document + "' ;;\nesac"
	writeTool(t, dir, "sudo", body)
	return dir, log
}

func writeTool(t *testing.T, dir, name, body string) {
	t.Helper()
	writeFile(t, filepath.Join(dir, name), "#!/bin/sh\n"+body+"\n", 0o700)
}

func writeFile(t *testing.T, path, body string, mode os.FileMode) {
	t.Helper()
	if err := os.WriteFile(path, []byte(body), mode); err != nil {
		t.Fatal(err)
	}
}

func readLines(t *testing.T, path string) []string {
	t.Helper()
	body, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return strings.Split(strings.TrimRight(string(body), "\n"), "\n")
}
