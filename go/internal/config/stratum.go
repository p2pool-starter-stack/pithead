package config

import (
	"encoding/json"
	"strconv"
	"strings"
)

type StratumEndpoint struct {
	Stage  string
	Bind   string
	Port   string
	Reason string
}

func ParseStratumEndpoint(raw []byte) (StratumEndpoint, error) {
	document, err := ParseDocument(raw)
	if err != nil || document == nil || duplicateError(document.root, "") != "" {
		return StratumEndpoint{}, ErrUnsupportedValidation
	}
	bind, err := networkScalar(document.root, "p2pool.stratum_bind", node{value: "0.0.0.0"}, false)
	if err != nil {
		return StratumEndpoint{}, ErrUnsupportedValidation
	}
	if !stratumIPv4(bind) {
		return StratumEndpoint{
			Stage:  "bind-error",
			Bind:   bind,
			Reason: `p2pool.stratum_bind must be an IPv4 address like "0.0.0.0", "127.0.0.1", or your LAN IP (got "` + bind + `").`,
		}, nil
	}
	port, err := networkScalar(document.root, "p2pool.stratum_port", node{value: json.Number("3333")}, false)
	if err != nil {
		return StratumEndpoint{}, ErrUnsupportedValidation
	}
	if !stratumPort(port) {
		return StratumEndpoint{
			Stage:  "port-error",
			Bind:   bind,
			Port:   port,
			Reason: `p2pool.stratum_port must be an integer between 1 and 65535 (got "` + port + `").`,
		}, nil
	}
	return StratumEndpoint{Stage: "ok", Bind: bind, Port: port}, nil
}

func stratumIPv4(value string) bool {
	parts := strings.Split(value, ".")
	if len(parts) != 4 {
		return false
	}
	for _, part := range parts {
		if len(part) < 1 || len(part) > 3 || !decimalDigits(part) {
			return false
		}
		octet, err := strconv.Atoi(part)
		if err != nil || octet > 255 {
			return false
		}
	}
	return true
}

func stratumPort(value string) bool {
	if len(value) < 1 || len(value) > 5 || !decimalDigits(value) {
		return false
	}
	port, err := strconv.Atoi(value)
	return err == nil && port >= 1 && port <= 65535
}
