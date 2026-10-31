//go:build parity

package doctor

import (
	"errors"
	"testing"

	"github.com/p2pool-starter-stack/pithead/go/internal/firewall"
)

func TestLANNFTSerializationFallbackParity(t *testing.T) {
	for _, test := range []struct {
		name, document, port string
		bashCode             int
	}{
		{"unicode separator", lanNFTDocument(`[{"comment":"\u2028"},{"drop":null}]`), "2028", 1},
		{"unicode key", lanNFTDocument(`[{"\u2029":"value"},{"drop":null}]`), "2029", 1},
		{"fractional exponent", lanNFTDocument(`[{"counter":{"packets":1e-7}},{"drop":null}]`), "7", 0},
		{"array chain", `{"nftables":[{"chain":{"name":"guard","hook":"forward"}},{"rule":{"chain":["guard"],"expr":[{"match":{"right":18081}},{"drop":null}]}}]}`, "18081", 0},
	} {
		t.Run(test.name, func(t *testing.T) {
			fixture := newLANFixture(t)
			lanNFT(t, fixture, test.document, 0)
			result := runLANBash(t, fixture, "readback", test.port)
			wantCalls := lanCalls(t, fixture, true)
			code, err := firewall.LANEnforced([]string{test.port})
			if result.code != test.bashCode || result.stdout != "" || result.stderr != "" || code != 0 || !errors.Is(err, firewall.ErrUnsupportedInput) {
				t.Fatalf("fallback witness: Bash %+v; Go %d, %v", result, code, err)
			}
			if calls := lanCalls(t, fixture, true); calls != wantCalls {
				t.Fatalf("fallback calls: Go %q; Bash %q", calls, wantCalls)
			}
		})
	}
}

func TestLANNFTEscapedSeparatorParity(t *testing.T) {
	fixture := newLANFixture(t)
	lanNFT(t, fixture, lanNFTDocument(`[{"comment":"\\u2028"},{"drop":null}]`), 0)
	assertLANReadbackParity(t, fixture, []string{"2028"}, 0)
}
