package config

import "github.com/p2pool-starter-stack/pithead/go/internal/payoutkeys"

type PayoutOwnershipInput struct {
	Chain         string
	AddressKeys   string
	PrivateView   string
	ExplicitSpend string
	DocsURL       string
}

type PayoutOwnershipResult struct {
	AssignSpend bool
	Spend       string
	Reason      string
}

func ValidatePayoutOwnership(input PayoutOwnershipInput) (PayoutOwnershipResult, error) {
	for index := 0; index < len(input.AddressKeys); index++ {
		if input.AddressKeys[index] > 0x7f {
			return PayoutOwnershipResult{}, ErrUnsupportedValidation
		}
	}
	switch input.Chain {
	case "monero":
		derived, valid := payoutkeys.Derive(input.Chain, input.PrivateView)
		if !valid {
			return PayoutOwnershipResult{Reason: "Cannot validate monero.view_key: python3 must be available and the key must be a nonzero canonical private scalar."}, nil
		}
		if derived != input.AddressKeys {
			return PayoutOwnershipResult{Reason: "monero.view_key does not belong to monero.wallet_address: the public view key differs. Use the secret (not public) view key of the wallet that owns this address; see " + input.DocsURL + "/docs/dashboard.md#getting-your-view-keys."}, nil
		}
		return PayoutOwnershipResult{}, nil
	case "tari":
		if len(input.AddressKeys) == 66 {
			return PayoutOwnershipResult{Reason: "Tari payout confirmation needs a dual-key address, which Tari Universe gives by default. A single-key address carries no public view key to check tari.view_key against. Mining payouts to single-key addresses remain supported."}, nil
		}
		if len(input.AddressKeys) != 130 {
			return PayoutOwnershipResult{Reason: "Cannot decode tari.wallet_address for payout confirmation; python3 must be available."}, nil
		}
		derived, valid := payoutkeys.Derive(input.Chain, input.PrivateView)
		if !valid {
			return PayoutOwnershipResult{Reason: "Cannot validate tari.view_key: python3 must be available and the key must be a nonzero canonical private scalar."}, nil
		}
		if derived != input.AddressKeys[2:66] {
			return PayoutOwnershipResult{Reason: "tari.view_key does not belong to tari.wallet_address: the public view key differs. Use the private view key of the wallet that owns this address; see " + input.DocsURL + "/docs/dashboard.md#getting-your-view-keys."}, nil
		}
		result := PayoutOwnershipResult{AssignSpend: true, Spend: input.AddressKeys[66:130]}
		if input.ExplicitSpend != "" && input.ExplicitSpend != result.Spend {
			result.Reason = "tari.spend_public_key disagrees with tari.wallet_address. Leave it empty to derive the public spend key from the address."
		}
		return result, nil
	default:
		return PayoutOwnershipResult{}, ErrUnsupportedValidation
	}
}
