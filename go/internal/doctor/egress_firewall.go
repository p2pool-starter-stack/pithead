package doctor

import "github.com/p2pool-starter-stack/pithead/go/internal/firewall"

const egressBootUnit = "pithead-egress.service"

type TorEgress struct {
	firewall.TorConfig
	Enabled   string
	OS        string
	Appliance bool
}

func (egress TorEgress) Findings() ([]Finding, error) {
	enabled, err := probeValue(egress.Enabled)
	if err != nil {
		return nil, err
	}
	if enabled == "" {
		enabled = "true"
	}
	check, err := exposureTLS(enabled)
	if err != nil {
		return nil, err
	}
	if !check {
		return []Finding{{"tor-egress-firewall", "info", "Tor-egress firewall check skipped — opted out (network.tor_egress_firewall=false)."}}, nil
	}
	running, err := ContainerRunning("tor")
	if err != nil {
		return nil, err
	}
	if !running {
		return []Finding{{"tor-egress-firewall", "info", "Tor-egress firewall check skipped — the tor container isn't running."}}, nil
	}
	engine, err := firewall.Engine()
	if err != nil {
		return nil, ErrUnsupportedProbeInput
	}
	code, err := firewall.TorEnforced(egress.TorConfig)
	if err != nil {
		return nil, ErrUnsupportedProbeInput
	}
	findings := []Finding{egress.finding(code, engine)}
	if code == 0 {
		applies, err := LANBootApplies(egress.OS, egress.Appliance)
		if err != nil {
			return nil, err
		}
		if applies {
			enabled, err := lanSystemctl(false, "is-enabled", egressBootUnit)
			if err != nil {
				return nil, err
			}
			if !enabled {
				findings = append(findings, Finding{"tor-egress-firewall", "warn", "The Tor-egress firewall is live but will NOT survive a reboot — " + egressBootUnit + " is not enabled, so the containers would restart without it. Run './pithead up' to install it."})
			}
		}
	}
	return findings, nil
}

func (egress TorEgress) finding(code int, engine string) Finding {
	how, reread := "iptables ("+firewall.EgressTag+" in DOCKER-USER)", "sudo iptables -S DOCKER-USER | grep "+firewall.EgressTag
	if engine == "podman" {
		how, reread = "nftables (inet pithead_egress)", "sudo nft list table inet pithead_egress"
	}
	status, message := "info", "Tor-egress firewall check skipped — reading the rules needs passwordless sudo. Verify manually: '"+reread+"'."
	if egress.Appliance {
		message = "Tor-egress firewall check skipped — the firewall rules could not be read on this machine."
	}
	switch code {
	case 0:
		status, message = "ok", "Tor-only egress firewall is installed — clearnet dials from the stack are fail-closed via "+how+"."
	case 1:
		status, message = "fail", "Tor-only egress firewall is MISSING while the stack runs — clearnet egress is NOT fail-closed. On a DIY host "+egressBootUnit+" restores it at boot, ahead of the containers; see 'systemctl status "+egressBootUnit+"'. Run './pithead up' to reinstall the rules and the unit."
		if egress.Appliance {
			message = "Tor-only egress firewall is MISSING while the stack runs — clearnet egress is NOT fail-closed. This happens after a reboot in which the rules were lost but the containers came back. Restarting this machine reinstalls them."
		}
	case 2:
		status, message = "fail", "Tor-only egress CANNOT be enforced — the "+how+" backend's command is not installed on this host, so nothing is dropping clearnet dials from the stack. Install it and run './pithead up', or set network.tor_egress_firewall=false to acknowledge running without it."
		if egress.Appliance {
			message = "Tor-only egress CANNOT be enforced on this machine — the firewall command it needs is missing, so clearnet dials from the stack are not being dropped."
		}
	case 4:
		status, message = "fail", "Tor-only egress rules are present in DOCKER-USER but NOTHING JUMPS TO IT — the chain is orphaned, so clearnet dials from the stack are NOT being dropped. This is what a container engine that does not add the FORWARD jump (or a firewall manager that removed it) leaves behind. Run './pithead up' to reinstall, and check that the engine manages iptables."
		if egress.Appliance {
			message = "Tor-only egress rules exist but are not being applied to traffic — the firewall chain is not connected, so clearnet dials from the stack are not being dropped. Restarting this machine reinstalls them."
		}
	case 5:
		status, message = "fail", "Tor-egress rules are installed, but a rule that is not ours sits ABOVE the DROP in DOCKER-USER — iptables is first-match-wins, so the DROP may never be reached and clearnet egress is NOT provably fail-closed. Inspect with 'sudo iptables -S DOCKER-USER'."
		if egress.Appliance {
			message = "Tor-egress rules are installed, but another firewall rule takes precedence over them, so clearnet egress cannot be confirmed as blocked on this machine."
		}
	}
	return Finding{"tor-egress-firewall", status, message}
}
