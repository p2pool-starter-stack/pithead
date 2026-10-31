package doctor

import (
	"strings"

	"github.com/p2pool-starter-stack/pithead/go/internal/onion"
)

var onionAddressNames = [...]string{
	"MONERO_ONION_ADDRESS",
	"TARI_ONION_ADDRESS",
	"P2POOL_ONION_ADDRESS",
}

var onionAddressProfiles = [...]string{
	"local_node",
	"local_tari",
	"",
}

type OnionAddresses struct {
	Profiles                           string
	Addresses                          []string
	DashboardEnabled, DashboardAddress string
	ClientAuth, Program                string
	Appliance                          bool
}

func (addresses OnionAddresses) Findings() ([]Finding, error) {
	profiles, err := probeValue(addresses.Profiles)
	if err != nil {
		return nil, err
	}
	profileSet := "," + profiles + ","
	findings := make([]Finding, 0, len(onionAddressNames)+1)
	for index, name := range onionAddressNames {
		needed := onionAddressProfiles[index]
		if needed != "" && !strings.Contains(profileSet, ","+needed+",") {
			findings = append(findings, Finding{"node-onion-address", "ok", name + " not needed — that node runs elsewhere, so it has no inbound hidden service."})
			continue
		}
		value := ""
		if index < len(addresses.Addresses) {
			value, err = probeValue(addresses.Addresses[index])
			if err != nil {
				return nil, err
			}
		}
		if onion.Missing(value) {
			display := value
			if display == "" {
				display = "empty"
			}
			message := name + " is not provisioned (value: '" + display + "') — re-run './pithead setup' to generate Tor hidden services."
			if addresses.Appliance {
				remedy := "This machine regenerates it the next time it applies its configuration, so saving any change from the dashboard provisions it."
				if name == "P2POOL_ONION_ADDRESS" {
					remedy = "This machine cannot finish applying its configuration while it is missing, so no dashboard surface regenerates it — correcting this needs console access."
				}
				message = name + " is not provisioned (value: '" + display + "') — its Tor hidden service has not been generated. " + remedy
			}
			findings = append(findings, Finding{"node-onion-address", "warn", message})
			continue
		}
		findings = append(findings, Finding{"node-onion-address", "ok", name + " set."})
	}

	enabled, line, err := addresses.dashboardStatus()
	if err != nil {
		return nil, err
	}
	if !enabled {
		return findings, nil
	}
	if line != "" {
		return append(findings, Finding{"dashboard-onion-address", "ok", "Dashboard onion: " + line}), nil
	}
	message := "DASHBOARD_ONION_ADDRESS is not provisioned yet — re-run './pithead setup' or './pithead apply'."
	if addresses.Appliance {
		message = "DASHBOARD_ONION_ADDRESS is not provisioned yet — the dashboard's own hidden service has not been generated. This machine regenerates it the next time it applies its configuration, so saving any change from the dashboard provisions it."
	}
	return append(findings, Finding{"dashboard-onion-address", "warn", message}), nil
}

func (addresses OnionAddresses) DashboardStatus() (string, error) {
	_, line, err := addresses.dashboardStatus()
	return line, err
}

func (addresses OnionAddresses) dashboardStatus() (bool, string, error) {
	enabled, err := probeValue(addresses.DashboardEnabled)
	if err != nil {
		return false, "", err
	}
	if enabled != "true" {
		return false, "", nil
	}
	address, err := probeValue(addresses.DashboardAddress)
	if err != nil {
		return false, "", err
	}
	if onion.Missing(address) {
		return true, "", nil
	}
	clientAuth, err := probeValue(addresses.ClientAuth)
	if err != nil {
		return false, "", err
	}
	if clientAuth == "true" && strings.ContainsRune(addresses.Program, 0) {
		return false, "", ErrUnsupportedProbeInput
	}
	return true, onion.Status(addresses.Program, address, clientAuth), nil
}
