package firewall

import (
	"errors"
	"testing"
)

func TestNFTSerializationFallbacks(t *testing.T) {
	for _, expr := range []string{
		`[{"comment":"\u2028"},{"drop":null}]`,
		`[{"\u2029":"value"},{"drop":null}]`,
		`[{"counter":{"packets":1e-7}},{"drop":null}]`,
		`[{"counter":{"packets":1e-100000000}},{"drop":null}]`,
		`[{"counter":{"packets":1e100000000}},{"drop":null}]`,
	} {
		if _, err := validateNFT(nftJSON("guard", expr), []string{"2028"}); !errors.Is(err, ErrUnsupportedInput) {
			t.Fatalf("validateNFT(%s): %v", expr, err)
		}
	}
	for _, test := range []struct{ expr, port string }{
		{`[{"comment":"\\u2028"},{"drop":null}]`, "2028"},
		{`[{"comment":"18081"},{"counter":{"packets":0}},{"drop":null}]`, "18081"},
	} {
		if ok, err := validateNFT(nftJSON("guard", test.expr), []string{test.port}); err != nil || !ok {
			t.Fatalf("supported expression %s: %t, %v", test.expr, ok, err)
		}
	}
}

func TestNFTNonStringChainFallback(t *testing.T) {
	document := `{"nftables":[{"chain":{"name":"guard","hook":"forward"}},{"rule":{"chain":["guard"],"expr":[{"match":{"right":18081}},{"drop":null}]}}]}`
	if _, err := validateNFT(document, []string{"18081"}); !errors.Is(err, ErrUnsupportedInput) {
		t.Fatalf("array-valued rule chain: %v", err)
	}
}
