//go:build parity

package doctor

import "testing"

func TestNFTEgressExceptionOrder(t *testing.T) {
	for _, test := range []string{"authorized", "missing", "inactive", "duplicate", "late", "conditional", "negated", "earlier-drop"} {
		t.Run(test, func(t *testing.T) {
			fixture := newNFTEgressFixture(t)
			fixture.Active = "172.28.0.26"
			accept := nftIPAccept("172.28.0.26")
			rules, want := [][]any{accept, nftSubnetDrop()}, 1
			switch test {
			case "authorized":
				want = 0
			case "missing":
				rules = [][]any{nftSubnetDrop()}
			case "inactive":
				fixture.Active = ""
			case "duplicate":
				rules = [][]any{accept, accept, nftSubnetDrop()}
			case "late":
				rules = [][]any{nftSubnetDrop(), accept}
			case "conditional":
				rules[0] = []any{accept[0], nftIPMatch("daddr", "10.0.0.1"), accept[1]}
			case "negated":
				accept[0].(map[string]any)["match"].(map[string]any)["op"] = "!="
			case "earlier-drop":
				rules = append([][]any{{nftIPMatch("saddr", "10.0.0.1"), map[string]any{"drop": nil}}}, rules...)
			}
			egressResponse(t, fixture, "nft", "table", nftEgressDocument(t, rules...), 0)
			compareEgressReadback(t, fixture, want)
		})
	}
}

func TestNFTEgressIPv6StructuralParity(t *testing.T) {
	for _, test := range []string{"interface-right", "first-meta-extra", "second-left-extra", "second-match-extra", "expression-extra"} {
		t.Run(test, func(t *testing.T) {
			fixture := newNFTEgressFixture(t)
			accept := nftIPv6LocalAccept("fc00::", 7)
			first := accept[0].(map[string]any)["match"].(map[string]any)
			second := accept[1].(map[string]any)["match"].(map[string]any)
			switch test {
			case "interface-right":
				first["right"] = []string{"fixture-a", "fixture-b"}
			case "first-meta-extra":
				first["left"].(map[string]any)["meta"].(map[string]any)["extra"] = "ignored"
			case "second-left-extra":
				second["left"].(map[string]any)["extra"] = "ignored"
			case "second-match-extra":
				second["extra"] = "ignored"
			case "expression-extra":
				accept[1].(map[string]any)["extra"] = "ignored"
			}
			egressResponse(t, fixture, "nft", "table", nftEgressDocument(t, nftSubnetDrop(), accept), 0)
			compareEgressReadback(t, fixture, 0)
		})
	}
}

func TestNFTEgressDoctorFindings(t *testing.T) {
	for _, test := range []string{"enforced", "missing-table", "sudo-refused", "missing-jq", "tor-stopped", "opt-out"} {
		for _, appliance := range []bool{false, true} {
			t.Run(test+boolText(appliance), func(t *testing.T) {
				fixture := newNFTEgressFixture(t)
				fixture.Appliance = appliance
				egressTool(t, fixture, "docker")
				egressResponse(t, fixture, "docker", "tor", "cid\n", 0)
				egressTool(t, fixture, "systemctl")
				switch test {
				case "missing-table":
					egressResponse(t, fixture, "nft", "table", "", 1)
				case "sudo-refused":
					egressResponse(t, fixture, "nft", "all", "", 1)
				case "missing-jq":
					removeNFTTool(t, fixture, "jq")
				case "tor-stopped":
					egressResponse(t, fixture, "docker", "tor", "", 0)
				case "opt-out":
					fixture.Enabled = "false"
				}
				compareEgressFindings(t, fixture)
			})
		}
	}
}
