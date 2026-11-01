package config

import (
	"strings"
	"unicode"
)

type WalletSettings struct {
	Assigned     int
	MoneroWallet string
	TariWallet   string
	Reason       string
}

func ParseWalletSettings(raw []byte, mode, configFile string) (WalletSettings, error) {
	settings := WalletSettings{}
	if mode != "local" && mode != "remote" && mode != "off" {
		settings.Reason = `tari.mode must be "local", "remote" or "off" (got "` + mode + `").`
		return settings, nil
	}
	document, err := ParseDocument(raw)
	if err != nil || document == nil || duplicateError(document.root, "") != "" {
		return WalletSettings{}, ErrUnsupportedValidation
	}
	settings.MoneroWallet, err = walletScalar(document.root, "monero.wallet_address")
	if err != nil {
		return WalletSettings{}, err
	}
	settings.TariWallet, err = walletScalar(document.root, "tari.wallet_address")
	if err != nil {
		return WalletSettings{}, err
	}
	settings.Assigned = 2
	if settings.MoneroWallet == "" || settings.TariWallet == "" && mode != "off" {
		settings.Reason = "Missing required wallet addresses in " + configFile + "."
		return settings, nil
	}
	whitespace, supported := walletWhitespace(settings.TariWallet)
	if !supported {
		return WalletSettings{}, ErrUnsupportedValidation
	}
	if whitespace {
		settings.Reason = "tari.wallet_address contains whitespace — a Tari address (base58 or emoji) has none. Check for a stray space or line break in " + configFile + "."
	}
	return settings, nil
}

func walletScalar(root node, path string) (string, error) {
	value, err := getStringPath(root, path)
	if err != nil || value.object != nil || value.array != nil {
		return "", ErrUnsupportedValidation
	}
	if text, ok := value.value.(string); ok {
		text = strings.TrimRight(text, "\n")
		_, supported := walletWhitespace(text)
		if !supported {
			return "", ErrUnsupportedValidation
		}
		return text, nil
	}
	result, err := networkSettingsScalar(root, path, node{value: ""}, false)
	if err != nil {
		return "", ErrUnsupportedValidation
	}
	if _, supported := walletWhitespace(result); !supported {
		return "", ErrUnsupportedValidation
	}
	return result, nil
}

func walletWhitespace(value string) (bool, bool) {
	whitespace := false
	for _, current := range value {
		switch current {
		case ' ', '\t', '\n', '\v', '\f', '\r':
			whitespace = true
		default:
			if current < 0x20 || current >= 0x7f && current <= 0x9f || unicode.IsSpace(current) {
				return false, false
			}
		}
	}
	return whitespace, true
}
