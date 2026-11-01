package api

import (
	"bytes"
	"encoding/json"
	"errors"
	"net"
	"strings"
)

type MinerConnectionInput struct {
	HostIP           string
	Bind             string
	Port             json.RawMessage
	DetectedHostIPv4 string
	Password         string
	TLS              string
	Fingerprint      string
}

func BuildMinerConnection(input MinerConnectionInput) (map[string]any, error) {
	host := input.Bind
	if host == "0.0.0.0" {
		host = input.HostIP
		if net.ParseIP(strings.TrimSpace(input.HostIP)) == nil && input.DetectedHostIPv4 != "" && input.DetectedHostIPv4 != input.HostIP {
			host = input.DetectedHostIPv4
		}
	}
	if strings.Contains(host, ":") && !strings.HasPrefix(host, "[") {
		host = "[" + host + "]"
	}
	port, err := connectionPort(input.Port)
	if err != nil {
		return nil, err
	}
	tls := input.TLS == "true"
	scheme := "tcp"
	fingerprint := ""
	if tls {
		scheme = "ssl"
		fingerprint = input.Fingerprint
	}
	return map[string]any{
		"url":          "stratum+" + scheme + "://" + host + ":" + port,
		"local_only":   input.Bind == "127.0.0.1",
		"password_set": input.Password != "",
		"password":     input.Password,
		"tls":          tls,
		"fingerprint":  fingerprint,
	}, nil
}

func connectionPort(raw json.RawMessage) (string, error) {
	raw = bytes.TrimSpace(raw)
	if len(raw) == 0 {
		return "3333", nil
	}
	if raw[0] == '"' {
		var value string
		if err := json.Unmarshal(raw, &value); err != nil || value == "" {
			return "", errors.New("invalid stratum port")
		}
		return value, nil
	}
	var value json.Number
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.UseNumber()
	if err := decoder.Decode(&value); err != nil || !jsonNumberComplete(decoder) {
		return "", errors.New("invalid stratum port")
	}
	if _, err := value.Int64(); err != nil {
		return "", errors.New("invalid stratum port")
	}
	return value.String(), nil
}
