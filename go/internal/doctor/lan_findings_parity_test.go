//go:build parity

package doctor

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestLANFindingsEnforcedParity(t *testing.T) {
	for _, test := range []string{"enabled", "disabled", "no-systemctl", "non-linux", "appliance", "unsafe-policy", "stopped"} {
		t.Run(test, func(t *testing.T) {
			fixture := newLANFixture(t)
			fixture.Binds = []string{"0.0.0.0", "::", "0.0.0.0"}
			lanIPTables(t, fixture, lanJump("18081")+lanJump("18083")+lanJump("18142"))
			if test != "no-systemctl" {
				lanTool(t, fixture, "systemctl")
				code := 0
				if test == "disabled" {
					code = 1
				}
				lanResponse(t, fixture, "systemctl", "enabled", "suppressed stdout\n", code)
			}
			lanTool(t, fixture, "docker")
			for _, container := range []string{"monerod", "tari"} {
				policy, running := "no", "cid\n"
				if test == "unsafe-policy" {
					policy = "unless-stopped"
				}
				if test == "stopped" {
					running = ""
				}
				lanResponse(t, fixture, "docker", container+"-policy", policy, 0)
				lanResponse(t, fixture, "docker", container+"-running", running, 0)
				lanResponse(t, fixture, "docker", container+"-code", "78", 0)
			}
			if test == "non-linux" {
				fixture.OS = "Darwin"
			}
			fixture.Appliance = test == "appliance"
			compareLANFindings(t, fixture, "findings")
		})
	}
}

func TestLANFindingsUnenforcedParity(t *testing.T) {
	for _, test := range []string{"stopped", "exposed", "loopback", "mixed", "failed-ps", "partial-ps", "failed-port", "ipv6-loopback", "empty-port", "empty-line"} {
		for _, appliance := range []bool{false, true} {
			t.Run(test+boolText(appliance), func(t *testing.T) {
				fixture := newLANFixture(t)
				fixture.Binds = []string{"0.0.0.0", "::", "0.0.0.0"}
				fixture.OS, fixture.Appliance = "Darwin", appliance
				lanTool(t, fixture, "docker")
				for _, container := range []string{"monerod", "tari"} {
					output, code := "cid\n", 0
					if test == "stopped" || (test == "mixed" && container == "tari") {
						output = ""
					}
					if test == "failed-ps" || test == "partial-ps" {
						code = 1
						if test == "failed-ps" {
							output = ""
						}
					}
					lanResponse(t, fixture, "docker", container+"-running", output, code)
				}
				for _, key := range []string{"rpc", "zmq", "grpc"} {
					output, code := "0.0.0.0:1\n", 0
					switch test {
					case "loopback":
						output = "127.0.0.1:1\n127.0.0.1:2\n"
					case "mixed":
						if key == "rpc" {
							output = "127.0.0.1:1\n"
						}
					case "failed-port":
						code = 1
					case "ipv6-loopback":
						output = "[::1]:1\n"
					case "empty-port":
						output = ""
					case "empty-line":
						output = "\n"
					}
					lanResponse(t, fixture, "docker", key, output, code)
				}
				compareLANFindings(t, fixture, "findings")
			})
		}
	}
}

func TestLANFindingsReadbackReasonsParity(t *testing.T) {
	for _, code := range []int{1, 2, 3, 4, 5} {
		t.Run(string(rune('0'+code)), func(t *testing.T) {
			fixture := newLANFixture(t)
			fixture.Binds, fixture.OS = []string{"0.0.0.0"}, "Darwin"
			if code != 2 {
				lanIPTables(t, fixture, lanJump("18081"))
			}
			switch code {
			case 1:
				lanResponse(t, fixture, "iptables", "chain", "-A PITHEAD-LAN -j RETURN\n", 0)
			case 3:
				lanResponse(t, fixture, "iptables", "all", "", 1)
			case 4:
				lanResponse(t, fixture, "iptables", "forward", "", 0)
			case 5:
				lanResponse(t, fixture, "iptables", "user", "-A DOCKER-USER -j ACCEPT\n"+lanJump("18081"), 0)
			}
			lanTool(t, fixture, "docker")
			lanResponse(t, fixture, "docker", "monerod-running", "cid", 0)
			lanResponse(t, fixture, "docker", "rpc", "0.0.0.0:1\n", 0)
			compareLANFindings(t, fixture, "findings")
		})
	}
}

func TestLANFindingsSilentParity(t *testing.T) {
	fixture := newLANFixture(t)
	fixture.Binds = []string{"127.0.0.1", "", "127.0.0.1\n"}
	compareLANFindings(t, fixture, "findings")
}

func TestLANFindingsPortPipefailParity(t *testing.T) {
	fixture := newLANFixture(t)
	fixture.Binds, fixture.OS = []string{"0.0.0.0"}, "Darwin"
	writeHostTool(t, fixture.Bin, "docker", "printf '%s\\n' \"$@\" >>\"$0.log\"\ncase \"$1\" in\nps) printf 'cid\\n' ;;\nport) exec /bin/cat \"$0.rpc.output\" ;;\n*) exit 99 ;;\nesac\n")
	lanResponse(t, fixture, "docker", "rpc", strings.Repeat("0.0.0.0:1\n", 100000), 0)
	compareLANFindings(t, fixture, "findings")
}

func TestLANFindingsToolFallbacks(t *testing.T) {
	for _, tool := range []string{"grep", "docker", "systemctl"} {
		t.Run(tool, func(t *testing.T) {
			fixture := newLANFixture(t)
			fixture.Binds = []string{"0.0.0.0"}
			lanTool(t, fixture, "docker")
			lanResponse(t, fixture, "docker", "monerod-policy", "no", 0)
			lanResponse(t, fixture, "docker", "monerod-running", "cid", 0)
			lanResponse(t, fixture, "docker", "rpc", "0.0.0.0:1\n", 0)
			if tool == "systemctl" {
				lanTool(t, fixture, "systemctl")
				lanIPTables(t, fixture, lanJump("18081"))
			}
			if err := os.Remove(filepath.Join(fixture.Bin, tool)); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(filepath.Join(fixture.Bin, tool), []byte("printf 'unexpected\\n'\n"), 0o755); err != nil {
				t.Fatal(err)
			}
			if _, err := fixture.Findings(); !errors.Is(err, ErrUnsupportedProbeInput) {
				t.Fatalf("fallback %s: %v", tool, err)
			}
		})
	}
}
