//go:build parity

package doctor

import (
	"errors"
	"strings"
	"testing"

	"github.com/p2pool-starter-stack/pithead/go/internal/firewall"
)

func TestLANReadbackIPTablesCodes(t *testing.T) {
	goodChain := "-N PITHEAD-LAN\n-A PITHEAD-LAN -j DROP\n"
	goodUser := lanJump("18081") + lanJump("18083")
	tests := []struct {
		name      string
		ports     []string
		chain     string
		user      string
		forward   string
		allCode   int
		chainCode int
		userCode  int
		want      int
	}{
		{"enforced", []string{"18081", "18083"}, goodChain, goodUser, "-A FORWARD -j DOCKER-USER\n", 0, 0, 0, 0},
		{"unreadable", []string{"18081"}, goodChain, lanJump("18081"), "-A FORWARD -j DOCKER-USER\n", 1, 0, 0, 3},
		{"missing chain", []string{"18081"}, "", lanJump("18081"), "-A FORWARD -j DOCKER-USER\n", 0, 1, 0, 1},
		{"nonterminal drop", []string{"18081"}, goodChain + "-A PITHEAD-LAN -j RETURN\n", lanJump("18081"), "-A FORWARD -j DOCKER-USER\n", 0, 0, 0, 1},
		{"missing jump", []string{"18081", "18083"}, goodChain, lanJump("18081"), "-A FORWARD -j DOCKER-USER\n", 0, 0, 0, 1},
		{"user unreadable", []string{"18081"}, goodChain, "", "-A FORWARD -j DOCKER-USER\n", 0, 0, 1, 1},
		{"foreign first", []string{"18081"}, goodChain, "-A DOCKER-USER -j ACCEPT\n" + lanJump("18081"), "-A FORWARD -j DOCKER-USER\n", 0, 0, 0, 5},
		{"forward absent", []string{"18081"}, goodChain, lanJump("18081"), "-A FORWARD -j OTHER\n", 0, 0, 0, 4},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			fixture := newLANFixture(t)
			lanIPTables(t, fixture, test.user)
			lanResponse(t, fixture, "iptables", "all", "", test.allCode)
			lanResponse(t, fixture, "iptables", "chain", test.chain, test.chainCode)
			lanResponse(t, fixture, "iptables", "user", test.user, test.userCode)
			lanResponse(t, fixture, "iptables", "forward", test.forward, 0)
			calls := assertLANReadbackParity(t, fixture, test.ports, test.want)
			if (test.name == "nonterminal drop" || test.name == "missing jump") && strings.Contains(calls, "FORWARD") {
				t.Fatalf("FORWARD read after decisive failure: %q", calls)
			}
		})
	}

	t.Run("backend missing", func(t *testing.T) {
		fixture := newLANFixture(t)
		assertLANReadbackParity(t, fixture, []string{"18081"}, 2)
	})
}

func TestLANReadbackIPTablesOrderAndPorts(t *testing.T) {
	tests := []struct {
		name  string
		ports []string
		user  string
		want  int
	}{
		{"zero ports", nil, "-A DOCKER-USER -j ACCEPT\n", 0},
		{"duplicate port", []string{"18081", "18081"}, lanJump("18081") + "-A DOCKER-USER -j RETURN\n", 0},
		{"foreign after jumps", []string{"18081", "18083"}, lanJump("18081") + lanJump("18083") + "-A DOCKER-USER -j ACCEPT\n", 0},
		{"egress rule ignored", []string{"18081"}, "-A DOCKER-USER -m comment --comment pithead-tor-egress -j ACCEPT\n" + lanJump("18081"), 0},
		{"foreign between jumps", []string{"18081", "18083"}, lanJump("18081") + "-A DOCKER-USER -j RETURN\n" + lanJump("18083"), 5},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			fixture := newLANFixture(t)
			lanIPTables(t, fixture, test.user)
			assertLANReadbackParity(t, fixture, test.ports, test.want)
		})
	}
}

func TestLANReadbackNFT(t *testing.T) {
	tests := []struct {
		name     string
		ports    []string
		document string
		want     int
	}{
		{"single rule", []string{"18081", "18083"}, lanNFTDocument(`[{"match":{"right":18081}},{"match":{"right":18083}},{"drop":null}]`), 0},
		{"split rules", []string{"18081", "18083"}, `{"nftables":[{"chain":{"name":"guard","hook":"forward"}},{"rule":{"chain":"guard","expr":[{"match":{"right":18081}},{"drop":null}]}},{"rule":{"chain":"guard","expr":[{"match":{"right":18083}},{"drop":null}]}}]}`, 1},
		{"wrong chain", []string{"18081"}, `{"nftables":[{"chain":{"name":"guard","hook":"forward"}},{"rule":{"chain":"other","expr":[{"match":{"right":18081}},{"drop":null}]}}]}`, 1},
		{"legacy accept first", []string{"18081"}, lanNFTDocument(`[{"accept":null},{"match":{"right":18081}},{"drop":null}]`), 0},
		{"decimal port", []string{"18081"}, lanNFTDocument(`[{"match":{"right":18081.0}},{"drop":null}]`), 0},
		{"exponent port", []string{"18081"}, lanNFTDocument(`[{"match":{"right":1.8081e4}},{"drop":null}]`), 0},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			fixture := newLANFixture(t)
			lanNFT(t, fixture, test.document, 0)
			assertLANReadbackParity(t, fixture, test.ports, test.want)
		})
	}
}

func TestLANReadbackFallbackWitnesses(t *testing.T) {
	t.Run("invalid port expression", func(t *testing.T) {
		fixture := newLANFixture(t)
		lanIPTables(t, fixture, lanJump("18081"))
		result := runLANBash(t, fixture, "readback", "[")
		if result.code != 1 || result.stderr == "" {
			t.Fatalf("Bash invalid regex witness = %+v", result)
		}
		if code, err := firewall.LANEnforced([]string{"["}); code != 0 || !errors.Is(err, firewall.ErrUnsupportedInput) {
			t.Fatalf("native invalid port = %d, %v", code, err)
		}
	})

	for _, test := range []struct {
		name     string
		document string
		bashCode int
	}{
		{"malformed JSON", `{`, 1},
		{"unsafe precision", lanNFTDocument(`[{"counter":{"packets":9007199254740993}},{"match":{"right":18081}},{"drop":null}]`), 0},
		{"later malformed rule", `{"nftables":[{"chain":{"name":"guard","hook":"forward"}},{"rule":{"chain":"guard","expr":[{"match":{"right":18081}},{"drop":null}]}},{"rule":{"chain":"guard","expr":[1]}}]}`, 1},
	} {
		t.Run(test.name, func(t *testing.T) {
			fixture := newLANFixture(t)
			lanNFT(t, fixture, test.document, 0)
			lanCalls(t, fixture, true)
			result := runLANBash(t, fixture, "readback", "18081")
			wantCalls := lanCalls(t, fixture, true)
			code, err := firewall.LANEnforced([]string{"18081"})
			if result.code != test.bashCode || result.stdout != "" || code != 0 || !errors.Is(err, firewall.ErrUnsupportedInput) {
				t.Fatalf("fallback witness: Bash %+v; Go %d, %v", result, code, err)
			}
			if calls := lanCalls(t, fixture, true); calls != wantCalls {
				t.Fatalf("fallback calls: Go %q; Bash %q", calls, wantCalls)
			}
		})
	}
}

func assertLANReadbackParity(t *testing.T, fixture lanFixture, ports []string, want int) string {
	t.Helper()
	lanCalls(t, fixture, true)
	result := runLANBash(t, fixture, "readback", ports...)
	wantCalls := lanCalls(t, fixture, true)
	code, err := firewall.LANEnforced(ports)
	if err != nil || code != want || result.code != code || result.stdout != "" || result.stderr != "" {
		t.Fatalf("LANEnforced(%v) = %d, %v; Bash %+v; want %d", ports, code, err, result, want)
	}
	if calls := lanCalls(t, fixture, true); calls != wantCalls {
		t.Fatalf("readback calls: Go %q; Bash %q", calls, wantCalls)
	}
	return wantCalls
}

func lanNFT(t *testing.T, fixture lanFixture, document string, code int) {
	t.Helper()
	t.Setenv("PITHEAD_ENGINE", "podman")
	lanTool(t, fixture, "nft")
	lanResponse(t, fixture, "nft", "all", "", 0)
	lanResponse(t, fixture, "nft", "table", document+"\n", code)
}

func lanNFTDocument(expr string) string {
	return `{"nftables":[{"chain":{"name":"guard","hook":"forward"}},{"rule":{"chain":"guard","expr":` + expr + `}}]}`
}
