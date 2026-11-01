package config

import (
	"encoding/json"
	"strconv"
	"strings"
)

type NetworkSettingsInput struct {
	MoneroMode string
	TariMode   string
	ConfigPath string
}

type NetworkSettings struct {
	Assigned int
	Values   [12]string
	Reason   string
}

func ParseNetworkSettings(raw []byte, input NetworkSettingsInput) (NetworkSettings, error) {
	document, err := ParseDocument(raw)
	if err != nil || document == nil || duplicateError(document.root, "") != "" {
		return NetworkSettings{}, ErrUnsupportedValidation
	}
	root := document.root
	settings := NetworkSettings{}
	settings.Values[0], err = networkSettingsScalar(root, "network.subnet", node{value: "172.28.0.0/24"}, false)
	if err != nil {
		return NetworkSettings{}, err
	}
	settings.Assigned = 1
	if !strings.HasSuffix(settings.Values[0], ".0/24") {
		settings.Reason = `network.subnet must be an X.Y.Z.0/24 block (got "` + settings.Values[0] + `").`
		return settings, nil
	}
	settings.Values[1] = strings.TrimSuffix(settings.Values[0], ".0/24")
	settings.Assigned = 2
	if !stratumIPv4(settings.Values[1] + ".0") {
		settings.Reason = `network.subnet is not a valid IPv4 /24 (got "` + settings.Values[0] + `").`
		return settings, nil
	}

	if settings.Values[2], err = networkSettingsScalar(root, "network.tor_egress_firewall", node{value: true}, true); err != nil {
		return NetworkSettings{}, err
	}
	settings.Values[2] = normalizedBool(settings.Values[2])
	if settings.Values[3], err = networkSettingsScalar(root, "tor.auto_heal", node{value: false}, true); err != nil {
		return NetworkSettings{}, err
	}
	settings.Values[3] = normalizedBool(settings.Values[3])
	if settings.Values[4], err = networkSettingsScalar(root, "tari.explorer_url", node{value: "https://textexplore.tari.com/?json"}, false); err != nil {
		return NetworkSettings{}, err
	}
	if settings.Values[5], err = networkSettingsScalar(root, "p2pool.clearnet", node{value: false}, true); err != nil {
		return NetworkSettings{}, err
	}
	settings.Values[5] = normalizedBool(settings.Values[5])
	settings.Assigned = 11

	if input.MoneroMode == "remote" {
		if settings.Values[6], err = networkSettingsScalar(root, "monero.remote.host", node{value: ""}, false); err != nil {
			return NetworkSettings{}, err
		}
		if settings.Values[6] == "" {
			settings.Reason = `monero.mode is "remote" but monero.remote.host is not set in ` + input.ConfigPath + "."
			return settings, nil
		}
		if !networkSettingsHost(settings.Values[6]) {
			settings.Reason = `monero.remote.host must be a hostname or IP literal (letters, digits, and . : _ - only, ≤253 chars). Got "` + settings.Values[6] + `".`
			return settings, nil
		}
		if settings.Values[7], err = networkSettingsScalar(root, "monero.remote.rpc_port", node{value: json.Number("18081")}, false); err != nil {
			return NetworkSettings{}, err
		}
		if !networkSettingsPort(settings.Values[7]) {
			settings.Reason = `monero.remote.rpc_port must be a TCP port 1–65535. Got "` + settings.Values[7] + `".`
			return settings, nil
		}
		if settings.Values[8], err = networkSettingsScalar(root, "monero.remote.zmq_port", node{value: json.Number("18083")}, false); err != nil {
			return NetworkSettings{}, err
		}
		if !networkSettingsPort(settings.Values[8]) {
			settings.Reason = `monero.remote.zmq_port must be a TCP port 1–65535. Got "` + settings.Values[8] + `".`
			return settings, nil
		}
	}

	if input.TariMode == "remote" {
		if settings.Values[9], err = networkSettingsScalar(root, "tari.remote.host", node{value: ""}, false); err != nil {
			return NetworkSettings{}, err
		}
		if settings.Values[9] == "" {
			settings.Reason = `tari.mode is "remote" but tari.remote.host is not set in ` + input.ConfigPath + "."
			return settings, nil
		}
		if !networkSettingsHost(settings.Values[9]) {
			settings.Reason = `tari.remote.host must be a hostname or IP literal (letters, digits, and . : _ - only, ≤253 chars). Got "` + settings.Values[9] + `".`
			return settings, nil
		}
		if settings.Values[10], err = networkSettingsScalar(root, "tari.remote.grpc_port", node{value: json.Number("18142")}, false); err != nil {
			return NetworkSettings{}, err
		}
		if !networkSettingsPort(settings.Values[10]) {
			settings.Reason = `tari.remote.grpc_port must be a TCP port 1–65535. Got "` + settings.Values[10] + `".`
			return settings, nil
		}
	}

	if settings.Values[11], err = networkSettingsScalar(root, "p2pool.pool", node{value: "mini"}, false); err != nil {
		return NetworkSettings{}, err
	}
	settings.Assigned = 12
	if settings.Values[11] != "main" && settings.Values[11] != "mini" && settings.Values[11] != "nano" {
		settings.Reason = `p2pool.pool must be "main", "mini", or "nano" (got "` + settings.Values[11] + `").`
	}
	return settings, nil
}

func networkSettingsScalar(root node, path string, fallback node, nullOnly bool) (string, error) {
	value, err := networkScalar(root, path, fallback, nullOnly)
	if err != nil {
		return "", ErrUnsupportedValidation
	}
	return value, nil
}

func networkSettingsHost(value string) bool {
	if len(value) < 1 || len(value) > 253 {
		return false
	}
	for index := 0; index < len(value); index++ {
		current := value[index]
		valid := current >= 'A' && current <= 'Z' ||
			current >= 'a' && current <= 'z' ||
			current >= '0' && current <= '9' ||
			strings.IndexByte(".:_-", current) >= 0
		if !valid {
			return false
		}
	}
	return true
}

func networkSettingsPort(value string) bool {
	if len(value) < 1 || len(value) > 5 || value[0] < '1' || value[0] > '9' || !decimalDigits(value) {
		return false
	}
	port, err := strconv.Atoi(value)
	return err == nil && port <= 65535
}
