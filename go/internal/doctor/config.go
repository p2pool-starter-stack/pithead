package doctor

import "github.com/p2pool-starter-stack/pithead/go/internal/address"

type ConfigDiagnostics struct {
	Present, Appliance                bool
	Variant, SSHEnabled, Monero, Tari string
	VerifyAddresses                   bool
	MoneroKeyOnly, TariKeyOnly        bool
}

func (config ConfigDiagnostics) Findings() ([]Finding, error) {
	if !config.Present {
		return nil, nil
	}
	var findings []Finding
	if config.Appliance {
		variant, err := probeValue(config.Variant)
		if err != nil {
			return nil, err
		}
		if variant == "release" {
			enabled, err := probeValue(config.SSHEnabled)
			if err != nil {
				return nil, err
			}
			if enabled == "true" {
				findings = append(findings, Finding{"ssh-release", "warn", "ssh.enabled is ignored on this release image — SSH is available only in a debug build."})
			}
		}
	}
	monero, err := probeValue(config.Monero)
	if err != nil {
		return nil, err
	}
	if monero != "" && monero != "your_monero_wallet_address" {
		for _, ch := range []byte(monero) {
			if ch >= 128 {
				return nil, ErrUnsupportedProbeInput
			}
		}
		findings = append(findings, config.moneroFinding(address.Monero(monero, config.VerifyAddresses, config.MoneroKeyOnly)))
	}
	tari, err := probeValue(config.Tari)
	if err != nil {
		return nil, err
	}
	if tari != "" && tari != "your_tari_wallet_address" {
		findings = append(findings, config.tariFinding(address.Tari(tari, config.VerifyAddresses, config.TariKeyOnly)))
	}
	return findings, nil
}

func (config ConfigDiagnostics) moneroFinding(kind string) Finding {
	finding := Finding{"monero-address-type", "fail", ""}
	switch kind {
	case "primary":
		finding.Status = "ok"
		finding.Message = "Monero payout address is a primary address (p2pool/XvB can pay it)."
	case "subaddress":
		finding.Message = "Monero payout address is a SUBADDRESS (8…) — p2pool CANNOT pay it, so you are NOT being paid. Set monero.wallet_address to your PRIMARY address (4…) and run './pithead apply'."
		if config.Appliance {
			finding.Message = "Monero payout address is a SUBADDRESS (8…) — p2pool CANNOT pay it, so you are NOT being paid. Open Configuration, replace it with your PRIMARY address (4…), and complete the confirmation step."
		}
	case "integrated":
		finding.Message = "Monero payout address is an INTEGRATED address — p2pool can't pay it. Use your plain PRIMARY address (4…)."
		if config.Appliance {
			finding.Message = "Monero payout address is an INTEGRATED address — p2pool can't pay it. Open Configuration, replace it with your plain PRIMARY address (4…), and complete the confirmation step."
		}
	case "checksum":
		finding.Message = "Monero payout address FAILS its checksum — at least one character is mistyped, and p2pool crashes on it at startup. Re-copy the address from your wallet into monero.wallet_address and run './pithead apply'."
		if config.Appliance {
			finding.Message = "Monero payout address FAILS its checksum — at least one character is mistyped, and p2pool crashes on it at startup. Open Configuration, re-copy it from your wallet, and complete the confirmation step."
		}
	default:
		finding.Status = "warn"
		finding.Message = "Monero payout address doesn't look like a primary address (expected 95 chars starting with 4)."
	}
	return finding
}

func (config ConfigDiagnostics) tariFinding(kind string) Finding {
	finding := Finding{"tari-address-type", "fail", ""}
	switch kind {
	case "ok":
		finding.Status = "ok"
		finding.Message = "Tari payout address passes its checksum."
	case "unchecked":
		finding.Status = "info"
		finding.Message = "Could not verify the Tari payout address checksum (no usable python3)."
	case "checksum":
		finding.Message = "Tari payout address FAILS its checksum — at least one character is mistyped, and Tari rewards are silently lost. Re-copy the address from your Tari wallet into tari.wallet_address and run './pithead apply'."
		if config.Appliance {
			finding.Message = "Tari payout address FAILS its checksum — at least one character is mistyped, and Tari rewards are silently lost. Open Configuration, re-copy it from your Tari wallet, and complete the confirmation step."
		}
	case "network":
		finding.Message = "Tari payout address is for a different Tari network — this stack mines MAINNET Tari. Set tari.wallet_address to your mainnet address and run './pithead apply'."
		if config.Appliance {
			finding.Message = "Tari payout address is for a different Tari network — this machine mines MAINNET Tari, and this address came from a testnet wallet. Open Configuration, replace it with your mainnet address, and complete the confirmation step."
		}
	default:
		finding.Status = "warn"
		finding.Message = "Tari payout address doesn't look like a valid Tari address (base58 or emoji form)."
	}
	return finding
}
