package config

import (
	"errors"
	"sort"
	"strconv"
	"strings"
)

var ErrUnsupportedValidation = errors.New("unsupported config validation")

func ValidateSection(raw []byte, section string) (string, bool, error) {
	if section != "workers" && section != "energy" && section != "webhooks" && section != "controls" {
		return "", false, ErrUnsupportedValidation
	}
	document, err := ParseDocument(raw)
	if err != nil || document == nil || duplicateError(document.root, "") != "" {
		return "", false, ErrUnsupportedValidation
	}
	if section != "controls" && section != "webhooks" && hasControlValue(document.root) {
		return "", false, ErrUnsupportedValidation
	}
	if section == "energy" && hasControlKey(document.root) {
		return "", false, ErrUnsupportedValidation
	}
	switch section {
	case "workers":
		return validateWorkers(document.root)
	case "energy":
		return validateEnergy(document.root)
	case "webhooks":
		return validateWebhooks(document.root)
	default:
		if hasControlValue(document.root) {
			return "control character", false, nil
		}
		return "", false, nil
	}
}

func validateWorkers(root node) (string, bool, error) {
	workers, err := objectField(root, "workers")
	if err != nil {
		return "", false, err
	}
	if isNull(workers) || workers.value == false {
		workers = node{object: []member{}}
	}
	if workers.object == nil {
		return "", false, ErrUnsupportedValidation
	}

	if apiPort, exists := objectValue(workers, "api_port"); exists && !isNull(apiPort) {
		invalid, unsupported := invalidFleetPort(apiPort)
		if unsupported {
			return "", false, ErrUnsupportedValidation
		}
		if invalid {
			return "workers.api_port must be an integer between 1 and 65535 (the fleet default worker API port).", false, nil
		}
	}
	list, exists := objectValue(workers, "list")
	if !exists || isNull(list) || list.value == false {
		list = node{array: []node{}}
	}
	if list.array == nil {
		return "workers.list must be an array of {name, host?, port?, token?, api_token?} objects.", false, nil
	}

	names := make([]string, 0, len(list.array))
	for _, entry := range list.array {
		if entry.object == nil {
			return "workers.list entries must be objects (got a " + jqType(entry) + ").", false, nil
		}
		nameNode, _ := objectValue(entry, "name")
		name, ok := nameNode.value.(string)
		if !ok || !printableASCII(name, 128) {
			return `workers.list: every entry needs a "name" of 1-128 printable non-space characters (its stratum worker name).`, false, nil
		}
		names = append(names, name)
		if value, exists := objectValue(entry, "host"); exists {
			host, stringValue := value.value.(string)
			if !stringValue || !validHost(host) {
				return "workers.list[" + name + "].host must be a hostname or IPv4 address (letters, digits, and . _ - only; no port or path).", false, nil
			}
		}
		for _, field := range []string{"port", "control_port"} {
			value, exists := objectValue(entry, field)
			if !exists {
				continue
			}
			invalid, unsupported := invalidIntegralPort(value)
			if unsupported {
				return "", false, ErrUnsupportedValidation
			}
			if invalid {
				if field == "port" {
					return "workers.list[" + name + "].port must be an integer between 1 and 65535.", false, nil
				}
				return "workers.list[" + name + "].control_port must be an integer between 1 and 65535 (the rig writable control API port, #185).", false, nil
			}
		}
		if value, exists := objectValue(entry, "token"); exists {
			token, stringValue := value.value.(string)
			if !stringValue || !printableASCII(token, 128) {
				return "workers.list[" + name + "].token must be 1-128 printable non-space characters.", false, nil
			}
		}
		if value, exists := objectValue(entry, "api_token"); exists {
			token, stringValue := value.value.(string)
			_, hasHost := objectValue(entry, "host")
			if !stringValue || !printableASCII(token, 128) || !hasHost {
				return "workers.list[" + name + "].api_token needs an operator-set host and 1-128 printable non-space characters.", false, nil
			}
		}
		if value, exists := objectValue(entry, "watts"); exists {
			invalid, unsupported := invalidWatts(value)
			if unsupported {
				return "", false, ErrUnsupportedValidation
			}
			if invalid {
				return "workers.list[" + name + "].watts must be a positive number of watts (a manual power-draw estimate for the energy calculator, #260).", false, nil
			}
		}
	}

	duplicates := duplicateStrings(names)
	if len(duplicates) != 0 {
		return "workers.list has duplicate names (" + strings.Join(duplicates, ", ") + ") — the first-declared entry wins; a renamed rig needs its config entry updated.", true, nil
	}
	return "", false, nil
}

func validateEnergy(root node) (string, bool, error) {
	dashboard, err := objectField(root, "dashboard")
	if err != nil {
		return "", false, err
	}
	energy := node{}
	if !isNull(dashboard) {
		if dashboard.object == nil {
			return "", false, ErrUnsupportedValidation
		}
		energy, _ = objectValue(dashboard, "energy")
	}
	if isNull(energy) || energy.value == false {
		energy = node{object: []member{}}
	}
	if energy.object == nil {
		return "dashboard.energy must be an object {cost_per_kwh, currency?, xmr_price?, tari_price?, price_feed?}.", false, nil
	}

	allowed := map[string]bool{"cost_per_kwh": true, "currency": true, "xmr_price": true, "tari_price": true, "price_feed": true}
	unknown := make([]string, 0)
	for _, item := range energy.object {
		if !allowed[item.key] {
			unknown = append(unknown, item.key)
		}
	}
	if len(unknown) != 0 {
		sort.Strings(unknown)
		return "dashboard.energy has an unknown key (" + strings.Join(unknown, ", ") + "). Only cost_per_kwh, currency, xmr_price, tari_price and price_feed are allowed.", false, nil
	}

	for _, field := range []struct {
		name   string
		reason string
	}{
		{"cost_per_kwh", "dashboard.energy.cost_per_kwh must be a non-negative number (your electricity price per kWh; 0 or unset hides the profit math)."},
		{"xmr_price", "dashboard.energy.xmr_price must be a non-negative number (the fiat price of 1 XMR in your currency; 0 or unset hides net profit)."},
		{"tari_price", "dashboard.energy.tari_price must be a non-negative number (the fiat price of 1 XTM in your currency; 0 or unset excludes Tari from net profit)."},
	} {
		value, exists := objectValue(energy, field.name)
		if !exists {
			continue
		}
		invalid, unsupported := invalidNonNegative(value)
		if unsupported {
			return "", false, ErrUnsupportedValidation
		}
		if invalid {
			return field.reason, false, nil
		}
	}
	if value, exists := objectValue(energy, "currency"); exists {
		currency, ok := value.value.(string)
		if !ok || !printableASCII(currency, 128) {
			return "dashboard.energy.currency must be a short currency label (e.g. USD, EUR).", false, nil
		}
	}
	if value, exists := objectValue(energy, "price_feed"); exists {
		if _, ok := value.value.(bool); !ok {
			return "dashboard.energy.price_feed must be true or false (fetch live XMR/XTM prices from CoinGecko over Tor; default false, no clearnet egress).", false, nil
		}
	}
	return "", false, nil
}

func validateWebhooks(root node) (string, bool, error) {
	notifications, err := objectField(root, "notifications")
	if err != nil {
		return "", false, err
	}
	hooks := node{}
	if !isNull(notifications) {
		if notifications.object == nil {
			return "", false, ErrUnsupportedValidation
		}
		hooks, _ = objectValue(notifications, "webhooks")
	}
	if isNull(hooks) {
		return "", false, nil
	}
	if hooks.array == nil {
		return "notifications.webhooks must be an array of URL strings.", false, nil
	}
	for index, hook := range hooks.array {
		if _, ok := hook.value.(string); !ok {
			return "notifications.webhooks[" + strconv.Itoa(index) + "] must be a URL string; null and other non-string members are not allowed.", false, nil
		}
	}
	return "", false, nil
}
