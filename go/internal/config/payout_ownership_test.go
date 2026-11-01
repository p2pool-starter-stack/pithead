package config

import (
	"strings"
	"testing"
)

const (
	ownershipPrivate = "01" + "00000000000000000000000000000000000000000000000000000000000000"
	ownershipMonero  = "5866666666666666666666666666666666666666666666666666666666666666"
	ownershipTari    = "e2f2ae0a6abc4e71a884a961c500515f58e30b6aa582dd8db6a65945e08d2d76"
)

func TestValidatePayoutOwnership(t *testing.T) {
	spend := strings.Repeat("ab", 32)
	tests := []struct {
		name  string
		input PayoutOwnershipInput
		want  PayoutOwnershipResult
	}{
		{"monero valid", PayoutOwnershipInput{Chain: "monero", AddressKeys: ownershipMonero, PrivateView: ownershipPrivate}, PayoutOwnershipResult{}},
		{"monero zero", PayoutOwnershipInput{Chain: "monero", AddressKeys: "mismatch", PrivateView: strings.Repeat("00", 32)}, PayoutOwnershipResult{Reason: "Cannot validate monero.view_key: python3 must be available and the key must be a nonzero canonical private scalar."}},
		{"monero order", PayoutOwnershipInput{Chain: "monero", AddressKeys: "mismatch", PrivateView: "edd3f55c1a631258d69cf7a2def9de1400000000000000000000000000000010"}, PayoutOwnershipResult{Reason: "Cannot validate monero.view_key: python3 must be available and the key must be a nonzero canonical private scalar."}},
		{"monero mismatch", PayoutOwnershipInput{Chain: "monero", AddressKeys: "mismatch", PrivateView: ownershipPrivate, DocsURL: "https://docs"}, PayoutOwnershipResult{Reason: "monero.view_key does not belong to monero.wallet_address: the public view key differs. Use the secret (not public) view key of the wallet that owns this address; see https://docs/docs/dashboard.md#getting-your-view-keys."}},
		{"tari single", PayoutOwnershipInput{Chain: "tari", AddressKeys: strings.Repeat("a", 66), PrivateView: strings.Repeat("00", 32)}, PayoutOwnershipResult{Reason: "Tari payout confirmation needs a dual-key address, which Tari Universe gives by default. A single-key address carries no public view key to check tari.view_key against. Mining payouts to single-key addresses remain supported."}},
		{"tari decode", PayoutOwnershipInput{Chain: "tari", AddressKeys: "bad", PrivateView: ownershipPrivate}, PayoutOwnershipResult{Reason: "Cannot decode tari.wallet_address for payout confirmation; python3 must be available."}},
		{"tari invalid before mismatch", PayoutOwnershipInput{Chain: "tari", AddressKeys: "00" + strings.Repeat("0", 128), PrivateView: strings.Repeat("00", 32)}, PayoutOwnershipResult{Reason: "Cannot validate tari.view_key: python3 must be available and the key must be a nonzero canonical private scalar."}},
		{"tari valid", PayoutOwnershipInput{Chain: "tari", AddressKeys: "00" + ownershipTari + spend, PrivateView: ownershipPrivate}, PayoutOwnershipResult{AssignSpend: true, Spend: spend}},
		{"tari spend mismatch", PayoutOwnershipInput{Chain: "tari", AddressKeys: "00" + ownershipTari + spend, PrivateView: ownershipPrivate, ExplicitSpend: strings.Repeat("cd", 32)}, PayoutOwnershipResult{AssignSpend: true, Spend: spend, Reason: "tari.spend_public_key disagrees with tari.wallet_address. Leave it empty to derive the public spend key from the address."}},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			got, err := ValidatePayoutOwnership(test.input)
			if err != nil || got != test.want {
				t.Fatalf("ValidatePayoutOwnership() = %#v, %v; want %#v, nil", got, err, test.want)
			}
		})
	}
}

func TestValidatePayoutOwnershipRejectsUnknownChain(t *testing.T) {
	for _, input := range []PayoutOwnershipInput{{Chain: "unknown"}, {Chain: "tari", AddressKeys: strings.Repeat("é", 66)}} {
		if got, err := ValidatePayoutOwnership(input); err != ErrUnsupportedValidation || got != (PayoutOwnershipResult{}) {
			t.Fatalf("ValidatePayoutOwnership(%#v) = %#v, %v", input, got, err)
		}
	}
}
