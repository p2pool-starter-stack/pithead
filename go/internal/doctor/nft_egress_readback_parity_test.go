//go:build parity

package doctor

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/p2pool-starter-stack/pithead/go/internal/firewall"
)

func TestNFTEgressReadbackCodes(t *testing.T) {
	for _, test := range []struct {
		name, key, output string
		status, want      int
	}{
		{"enforced", "", "", 0, 0},
		{"sudo-refused", "all", "partial", 1, 3},
		{"table-absent", "table", "", 1, 1},
		{"table-partial-failure", "table", "partial", 1, 1},
		{"drop-absent", "table", `{"nftables":[]}`, 0, 1},
	} {
		t.Run(test.name, func(t *testing.T) {
			fixture := newNFTEgressFixture(t)
			if test.key != "" {
				egressResponse(t, fixture, "nft", test.key, test.output, test.status)
			}
			compareEgressReadback(t, fixture, test.want)
		})
	}
	for _, tool := range []string{"jq", "sudo"} {
		t.Run("missing-"+tool, func(t *testing.T) {
			fixture := newNFTEgressFixture(t)
			if err := os.Remove(filepath.Join(fixture.lan.Bin, tool)); err != nil {
				t.Fatal(err)
			}
			compareEgressReadback(t, fixture, 3)
		})
	}
}

func TestNFTEgressSafeRules(t *testing.T) {
	for _, test := range []string{"complete", "active-sync", "ipv6", "custom-config", "numeric-form"} {
		t.Run(test, func(t *testing.T) {
			fixture := newNFTEgressFixture(t)
			expressions := [][]any{nftReplyAccept(), nftIPAccept("172.28.0.25"), nftLocalAccept("10.0.0.0", 8), nftLocalAccept("172.16.0.0", 12), nftLocalAccept("192.168.0.0", 16), nftLocalAccept("100.64.0.0", 10)}
			if test == "active-sync" {
				fixture.Active = "172.28.0.26\n172.28.0.27\n172.28.0.28\n172.28.0.29\n"
				for _, ip := range strings.Fields(fixture.Active) {
					expressions = append(expressions, nftIPAccept(ip))
				}
			}
			expressions = append(expressions, []any{nftIPMatch("saddr", nftPrefix("172.28.0.0", 24)), map[string]any{"reject": map[string]any{"type": "tcp reset"}}}, nftSubnetDrop())
			if test == "ipv6" {
				expressions = append(expressions, nftIPv6LocalAccept("fc00::", 7), nftIPv6LocalAccept("fe80::", 10))
			}
			document := nftEgressDocument(t, expressions...)
			if test == "custom-config" {
				fixture.Prefix, fixture.Subnet = "10.77.3", "10.77.3.0/24"
				document = strings.ReplaceAll(document, "172.28.0", "10.77.3")
			}
			if test == "numeric-form" {
				document = strings.ReplaceAll(document, `"len":24`, `"len":2.4e1`)
			}
			egressResponse(t, fixture, "nft", "table", document, 0)
			compareEgressReadback(t, fixture, 0)
		})
	}
}

func TestNFTEgressPrecedence(t *testing.T) {
	for _, test := range []struct {
		name string
		expr []any
		want int
	}{
		{"bare-accept", []any{map[string]any{"accept": nil}}, 1},
		{"counter-accept", []any{map[string]any{"counter": map[string]any{"packets": 0, "bytes": 0}}, map[string]any{"accept": nil}}, 1},
		{"log-accept", []any{map[string]any{"log": nil}, map[string]any{"accept": nil}}, 1},
		{"foreign-conditional", nftIPAccept("0.0.0.0/0"), 1},
		{"safe-tor", nftIPAccept("172.28.0.25"), 0},
		{"reject-first", []any{map[string]any{"reject": nil}}, 0},
		{"state-order", []any{map[string]any{"match": map[string]any{"op": "==", "left": map[string]any{"ct": map[string]any{"key": "direction"}}, "right": "reply"}}, map[string]any{"match": map[string]any{"op": "in", "left": map[string]any{"ct": map[string]any{"key": "state"}}, "right": []string{"related", "established"}}}, map[string]any{"accept": nil}}, 1},
	} {
		t.Run(test.name, func(t *testing.T) {
			fixture := newNFTEgressFixture(t)
			egressResponse(t, fixture, "nft", "table", nftEgressDocument(t, test.expr, nftSubnetDrop()), 0)
			compareEgressReadback(t, fixture, test.want)
		})
	}
	for _, test := range []struct{ name, old, next string }{
		{"wrong-chain", `"name":"forward"`, `"name":"other"`},
		{"wrong-hook", `"hook":"forward"`, `"hook":"input"`},
		{"unhooked-drop", `"chain":"forward"`, `"chain":"other"`},
		{"no-hook", `"hook":"forward",`, ``},
	} {
		t.Run(test.name, func(t *testing.T) {
			fixture := newNFTEgressFixture(t)
			document := strings.ReplaceAll(nftEgressDocument(t, nftSubnetDrop()), test.old, test.next)
			egressResponse(t, fixture, "nft", "table", document, 0)
			compareEgressReadback(t, fixture, 1)
		})
	}
}

func TestNFTEgressFallbacks(t *testing.T) {
	for _, test := range []struct{ name, document string }{
		{"malformed-json", `{`},
		{"array-chain", `{"nftables":[{"chain":{"name":"forward","hook":"forward"}},{"rule":{"chain":["forward"],"expr":[]}}]}`},
		{"unsafe-number", `{"nftables":[{"metainfo":{"number":9007199254740993}}]}`},
	} {
		t.Run(test.name, func(t *testing.T) {
			fixture := newNFTEgressFixture(t)
			egressResponse(t, fixture, "nft", "table", test.document, 0)
			result := runEgressBash(t, fixture, "readback")
			if result.code != 1 || result.stdout != "" || result.stderr != "" {
				t.Fatalf("Bash malformed witness: %+v", result)
			}
			if _, err := firewall.TorEnforced(fixture.TorConfig); !errors.Is(err, firewall.ErrUnsupportedInput) {
				t.Fatalf("fallback: %v", err)
			}
		})
	}
	t.Run("backend-missing", func(t *testing.T) {
		fixture := newEgressFixture(t)
		t.Setenv("PITHEAD_ENGINE", "podman")
		result := runEgressBash(t, fixture, "readback")
		if result.code != 2 || result.stdout != "" || result.stderr != "" {
			t.Fatalf("missing-backend witness: %+v", result)
		}
		if _, err := firewall.TorEnforced(fixture.TorConfig); !errors.Is(err, firewall.ErrUnsupportedInput) {
			t.Fatalf("missing-backend compatibility fallback: %v", err)
		}
	})
}
