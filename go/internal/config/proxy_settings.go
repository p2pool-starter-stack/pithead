package config

import (
	"encoding/json"
	"strconv"
	"strings"
)

type ProxySettings struct {
	Assigned int
	Values   [3]string
	Reason   string
}

func ParseProxySettings(raw []byte) (ProxySettings, error) {
	document, err := ParseDocument(raw)
	if err != nil || document == nil || duplicateError(document.root, "") != "" {
		return ProxySettings{}, ErrUnsupportedValidation
	}
	root := document.root
	settings := ProxySettings{}
	settings.Values[0], err = networkSettingsScalar(root, "p2pool.stratum_password", node{value: ""}, false)
	if err != nil || settings.Values[0] == "auto" {
		return ProxySettings{}, ErrUnsupportedValidation
	}
	settings.Assigned = 1
	if !proxyPassword(settings.Values[0]) {
		settings.Reason = `p2pool.stratum_password must be "auto", empty, or 1–128 chars of letters, digits, and . _ : @ - (no spaces or quotes).`
		return settings, nil
	}

	settings.Values[1], err = networkSettingsScalar(root, "p2pool.stratum_tls", node{value: false}, true)
	if err != nil {
		return ProxySettings{}, ErrUnsupportedValidation
	}
	settings.Values[1] = normalizedBool(settings.Values[1])
	settings.Assigned = 2

	settings.Values[2], err = networkSettingsScalar(root, "proxy.donate_level", node{value: json.Number("0")}, false)
	if err != nil {
		return ProxySettings{}, ErrUnsupportedValidation
	}
	settings.Assigned = 3
	valid, supported := proxyDonateLevel(settings.Values[2])
	if !supported {
		return ProxySettings{}, ErrUnsupportedValidation
	}
	if !valid {
		settings.Reason = `proxy.donate_level must be an integer 0–99 (percent); default 0 (got "` + settings.Values[2] + `").`
	}
	return settings, nil
}

func proxyPassword(value string) bool {
	if value == "" {
		return true
	}
	if len(value) > 128 {
		return false
	}
	for index := 0; index < len(value); index++ {
		current := value[index]
		valid := current >= 'A' && current <= 'Z' ||
			current >= 'a' && current <= 'z' ||
			current >= '0' && current <= '9' ||
			strings.IndexByte("._:@-", current) >= 0
		if !valid {
			return false
		}
	}
	return true
}

func proxyDonateLevel(value string) (bool, bool) {
	if !decimalDigits(value) {
		return false, true
	}
	if strings.Trim(value, "0") == "" {
		return true, true
	}
	parsed, err := strconv.ParseInt(value, 10, 64)
	if err != nil {
		return false, false
	}
	return parsed <= 99, true
}
