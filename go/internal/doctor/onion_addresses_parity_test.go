//go:build parity

package doctor

import (
	"strconv"
	"testing"

	"github.com/p2pool-starter-stack/pithead/go/internal/onion"
)

func TestOnionMissingFunction(t *testing.T) {
	for _, value := range []string{"", "placeholder", "placeholder\n", "PLACEHOLDER", " ", "0", "null", "example.onion"} {
		t.Run(strconv.Quote(value), func(t *testing.T) {
			input := newOnionFixture(t)
			input.Addresses = []string{value}
			result := runOnionBash(t, input, "missing")
			code := 1
			if onion.Missing(value) {
				code = 0
			}
			if result.code != code || result.stdout != "" || result.stderr != "" {
				t.Fatalf("Bash %+v, Go missing %v", result, onion.Missing(value))
			}
		})
	}
}

func TestOnionProfileTokens(t *testing.T) {
	for _, profiles := range []string{"", "local_node", "local_tari", "local_node,local_tari", "local_node_extra,local_tari_extra", " local_node,local_tari ", "LOCAL_NODE,LOCAL_TARI", "other,local_node,,local_tari,other", "local_node\n,local_tari", "local_node,local_tari\n\n"} {
		for _, appliance := range []bool{false, true} {
			t.Run(strconv.Quote(profiles)+"/"+boolName(appliance), func(t *testing.T) {
				input := newOnionFixture(t)
				input.Profiles, input.Appliance = profiles, appliance
				input.Addresses = []string{"", "placeholder", "placeholder"}
				compareOnionFindings(t, input)
			})
		}
	}
}

func TestOnionNodeAddresses(t *testing.T) {
	for _, value := range []string{"", "placeholder", "placeholder\n\n", "example.onion", "PLACEHOLDER", "false", " ", "line\nvalue", "quote'and=equals"} {
		for _, appliance := range []bool{false, true} {
			t.Run(strconv.Quote(value)+"/"+boolName(appliance), func(t *testing.T) {
				input := newOnionFixture(t)
				input.Addresses, input.Appliance = []string{value, value, value}, appliance
				compareOnionFindings(t, input)
			})
		}
	}
}

func TestOnionDashboardStatus(t *testing.T) {
	for _, state := range []struct{ enabled, address, auth string }{
		{"", "dashboard.onion", "true"},
		{"false", "dashboard.onion", "true"},
		{"TRUE", "dashboard.onion", "true"},
		{"yes", "dashboard.onion", "true"},
		{"true ", "dashboard.onion", "true"},
		{"true", "", "true"},
		{"true", "placeholder", "true"},
		{"true", "dashboard.onion", ""},
		{"true", "dashboard.onion", "false"},
		{"true", "dashboard.onion", "TRUE"},
		{"true", "dashboard.onion", "true"},
		{"true\n\n", "dashboard.onion\n", "true\n"},
	} {
		t.Run(strconv.Quote(state.enabled+"/"+state.address+"/"+state.auth), func(t *testing.T) {
			input := newOnionFixture(t)
			input.DashboardEnabled, input.DashboardAddress, input.ClientAuth = state.enabled, state.address, state.auth
			compareOnionStatus(t, input)
		})
	}
}

func TestOnionDashboardFindings(t *testing.T) {
	for _, enabled := range []string{"", "false", "TRUE", "true"} {
		for _, address := range []string{"", "placeholder", "dashboard.onion"} {
			for _, appliance := range []bool{false, true} {
				t.Run(enabled+"/"+address+"/"+boolName(appliance), func(t *testing.T) {
					input := newOnionFixture(t)
					input.DashboardEnabled, input.DashboardAddress, input.Appliance = enabled, address, appliance
					input.ClientAuth = "true"
					compareOnionFindings(t, input)
				})
			}
		}
	}
}

func TestOnionProgramNames(t *testing.T) {
	for _, program := range []string{"", "./pithead", "/fixture install/pithead", "tool'and=quoted", "tool\\name", "tool\nnext", "tool\n"} {
		t.Run(strconv.Quote(program), func(t *testing.T) {
			input := newOnionFixture(t)
			input.Program, input.ClientAuth = program, "true"
			compareOnionStatus(t, input)
			compareOnionFindings(t, input)
		})
	}
}

func TestOnionGetterNewlines(t *testing.T) {
	for _, address := range []string{"\n\n", "placeholder\n\n", "value\n\n", "line\nvalue"} {
		t.Run(strconv.Quote(address), func(t *testing.T) {
			input := newOnionFixture(t)
			input.Profiles += "\n\n"
			input.DashboardEnabled, input.ClientAuth = "true\n\n", "true\n\n"
			input.Addresses, input.DashboardAddress = []string{address, address, address}, address
			compareOnionStatus(t, input)
			compareOnionFindings(t, input)
		})
	}
}

func TestOnionShortAndExtraAddresses(t *testing.T) {
	for index, values := range [][]string{nil, {""}, {"", "node.onion"}, {"", "node.onion", "pool.onion", "ignored"}} {
		t.Run(strconv.Itoa(index), func(t *testing.T) {
			input := newOnionFixture(t)
			input.Addresses = values
			compareOnionFindings(t, input)
		})
	}
}
