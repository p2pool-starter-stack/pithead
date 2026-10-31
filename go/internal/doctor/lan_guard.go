package doctor

import (
	"strconv"
	"strings"

	"github.com/p2pool-starter-stack/pithead/go/internal/firewall"
)

const lanBootUnit = "pithead-lan-guard.service"
const lanCheckTimer = "pithead-lan.timer"

var lanBindPairs = [...]string{"MONERO_RPC_BIND:18081", "MONERO_ZMQ_BIND:18083", "TARI_GRPC_BIND:18142"}

type LANGuard struct {
	Binds     []string
	OS        string
	Appliance bool
}

func LANPublished(binds []string) ([]string, error) {
	var published []string
	for index, pair := range lanBindPairs {
		if index >= len(binds) {
			break
		}
		bind, err := probeValue(binds[index])
		if err != nil {
			return nil, err
		}
		if bind != "" && bind != "127.0.0.1" {
			published = append(published, pair)
		}
	}
	return published, nil
}

func lanContainer(port string) string {
	if port == "18142" {
		return "tari"
	}
	return "monerod"
}

func LANReason(code string) (string, error) {
	if strings.ContainsRune(code, 0) {
		return "", ErrUnsupportedProbeInput
	}
	switch code {
	case "1":
		return "the rule is not in the live ruleset", nil
	case "2":
		engine, err := firewall.Engine()
		if err != nil {
			return "", ErrUnsupportedProbeInput
		}
		tool := "iptables"
		if engine == "podman" {
			tool = "nft"
		}
		return "the " + tool + " command is not installed", nil
	case "3":
		return "installing or reading it needs root (passwordless sudo)", nil
	case "4":
		return "nothing jumps from FORWARD to DOCKER-USER", nil
	case "5":
		return "a firewall rule that is not ours accepts traffic above it in DOCKER-USER", nil
	case "6":
		return "the boot unit that restores it after a reboot could not be installed", nil
	case "7":
		return "the marker the node containers check could not be written", nil
	default:
		return "the readback failed (rc " + code + ")", nil
	}
}

func LANBootApplies(osType string, appliance bool) (bool, error) {
	if osType != "Linux" {
		return false, nil
	}
	path, err := networkTool("systemctl")
	if err != nil || path == "" {
		return false, err
	}
	if appliance {
		return false, nil
	}
	engine, err := firewall.Engine()
	if err != nil {
		return false, ErrUnsupportedProbeInput
	}
	return engine == "docker", nil
}

func (guard LANGuard) Findings() ([]Finding, error) {
	published, err := LANPublished(guard.Binds)
	if err != nil || len(published) == 0 {
		return nil, err
	}
	ports := make([]string, len(published))
	for index, pair := range published {
		_, ports[index], _ = strings.Cut(pair, ":")
	}
	findings, err := guard.Hold(ports)
	if err != nil {
		return nil, err
	}
	code, err := firewall.LANEnforced(ports)
	if err != nil {
		return nil, ErrUnsupportedProbeInput
	}
	portText := strings.Join(ports, " ")
	if code == 0 {
		applies, err := LANBootApplies(guard.OS, guard.Appliance)
		if err != nil {
			return nil, err
		}
		if applies {
			enabled, err := lanSystemctl(false, "is-enabled", lanBootUnit)
			if err != nil {
				return nil, err
			}
			if !enabled {
				message := "LAN-only sources are enforced on port(s) " + portText + " now, but " + lanBootUnit + " is not enabled, so a reboot reopens them to every source until './pithead up'. Run './pithead up' to install it."
				if guard.Appliance {
					message = "Node port(s) " + portText + " are limited to the LAN now, but that limit will not survive a restart of this machine."
				}
				return append(findings, Finding{"lan-guard", "warn", message}), nil
			}
		}
		return append(findings, Finding{"lan-guard", "ok", "LAN-only sources enforced on port(s) " + portText + ": loopback, private and CGNAT addresses only."}), nil
	}
	var exposed []string
	running := false
	for _, port := range ports {
		container := lanContainer(port)
		up, err := ContainerRunning(container)
		if err != nil {
			return nil, err
		}
		if !up {
			continue
		}
		running = true
		open, err := lanPortExposed(container, port)
		if err != nil {
			return nil, err
		}
		if open {
			exposed = append(exposed, port)
		}
	}
	if !running {
		return append(findings, Finding{"lan-guard", "info", "LAN-only source check skipped — the node containers aren't running."}), nil
	}
	reason, err := LANReason(strconv.Itoa(code))
	if err != nil {
		return nil, err
	}
	if len(exposed) != 0 {
		exposedText := strings.Join(exposed, " ")
		message := "Port(s) " + exposedText + " are published on every interface with NO LAN-only source rule (" + reason + "), so any address that can route to this host can connect. Run './pithead up' to reinstall it."
		if guard.Appliance {
			message = "Node port(s) " + exposedText + " are open to every network, not just the LAN: the rule that limits them is missing (" + reason + "). Restarting this machine reinstalls it."
		}
		return append(findings, Finding{"lan-guard", "fail", message}), nil
	}
	message := "LAN access is on for port(s) " + portText + ", but they are held on 127.0.0.1: the LAN-only source rule cannot be installed (" + reason + "). Fix that and run './pithead up'."
	if guard.Appliance {
		message = "LAN access is on for node port(s) " + portText + ", but they are only reachable from this machine: the rule that limits them to the LAN cannot be installed (" + reason + ")."
	}
	return append(findings, Finding{"lan-guard", "warn", message}), nil
}
