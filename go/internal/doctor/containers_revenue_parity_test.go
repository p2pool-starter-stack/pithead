//go:build parity

package doctor

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestContainerParityRevenueVerdicts(t *testing.T) {
	input := newContainerParityFixture(t, "docker")
	states := [][2]string{
		{"running", "Up (healthy)"}, {"running", "Up (starting)"},
		{"running", "Up (unhealthy)"}, {"exited", "Exited (1)"},
		{"created", "Created"}, {"stopped", "Stopped"},
		{"restarting", "Restarting (1)"}, {"paused", "Up (Paused)"},
		{"", "Up 1 minute"}, {"", "Exited (0)"}, {"", ""},
	}
	for _, name := range []string{"monerod", "tari", "wallet-rpc", "tari-wallet", "p2pool", "xmrig-proxy"} {
		for _, hold := range []string{"0", "1"} {
			for _, pair := range states {
				t.Run(name+"/"+hold+"/"+pair[0]+"/"+pair[1], func(t *testing.T) {
					compareContainerVerdict(t, input, name, pair[0], pair[1], hold)
				})
			}
		}
	}
}

func TestContainerParityRevenueNames(t *testing.T) {
	input := newContainerParityFixture(t, "podman")
	for _, name := range []string{"abcdef123456_monerod", "abcdef123456_p2pool", "ABCDEF123456_monerod", "/monerod", "caddy", "unknown", "", "monerod tari", "tari wallet-rpc", "p2pool xmrig-proxy"} {
		t.Run(name, func(t *testing.T) {
			compareContainerVerdict(t, input, name, "exited", "Exited (1)", "0")
		})
	}
}

func TestContainerParityRevenueRows(t *testing.T) {
	for _, engine := range []string{"docker", "podman"} {
		for _, rows := range []struct{ name, value string }{
			{"healthy", "monerod\trunning\tUp (healthy)\np2pool\texited\tExited (0)\n"},
			{"faults", "monerod\texited\tExited (1)\np2pool\trestarting\tRestarting\n"},
			{"adjacent-service-names", "monerod tari\texited\tExited (1)\np2pool xmrig-proxy\trestarting\tRestarting\n"},
			{"duplicate", "monerod\texited\tExited (1)\nmonerod\texited\tExited (1)\n"},
			{"collapsed-empty-state", "monerod\t\tUp (healthy)\n"},
			{"leading-tabs", "\tmonerod\trunning\tUp\twith extra\tfields\t\n"},
			{"name-only", "monerod\n"},
			{"blank-rows", "\n\t\nunknown\trestarting\tRestarting\n"},
		} {
			t.Run(engine+"/"+rows.name, func(t *testing.T) {
				input := newContainerParityFixture(t, engine)
				input.write(t, "ps.value", rows.value)
				compareContainerFindings(t, input, "revenue")
			})
		}
	}
}

func TestContainerParityRevenueGates(t *testing.T) {
	for _, name := range []string{"empty", "failed-partial", "no-engine", "hold-stopped", "hold-fault", "hold-empty"} {
		t.Run(name, func(t *testing.T) {
			input := newContainerParityFixture(t, "podman")
			switch name {
			case "empty", "hold-empty":
				input.write(t, "ps.value", "")
			case "failed-partial":
				input.write(t, "ps.value", "monerod\texited\tExited (1)\n")
				input.write(t, "ps.code", "1")
			case "no-engine":
				if err := os.Remove(filepath.Join(input.dir, "podman")); err != nil {
					t.Fatal(err)
				}
			case "hold-stopped":
				input.write(t, "ps.value", "monerod\texited\tExited (0)\ntari\tcreated\tCreated\n")
			case "hold-fault":
				input.write(t, "ps.value", "monerod\trunning\tUp (unhealthy)\n")
			}
			input.hold = strings.HasPrefix(name, "hold-")
			compareContainerFindings(t, input, "revenue")
		})
	}
}
