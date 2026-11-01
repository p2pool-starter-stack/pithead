package config

import (
	"encoding/json"
	"strconv"
	"strings"
)

type MoneroPayoutSettings struct {
	Assigned   int
	Mode       string
	ViewKey    string
	ScanHeight string
	Enabled    string
	Reason     string
}

type TariPayoutSettings struct {
	ViewKey        string
	SpendPublicKey string
	Birthday       string
	Enabled        string
	Reason         string
}

func ParseMoneroPayoutSettings(raw []byte, docsURL string) (MoneroPayoutSettings, error) {
	root, err := payoutDocument(raw)
	if err != nil || !payoutASCII(docsURL) {
		return MoneroPayoutSettings{}, ErrUnsupportedValidation
	}
	settings := MoneroPayoutSettings{}
	settings.Mode, err = payoutScalar(root, "monero.mode", "local")
	if err != nil {
		return MoneroPayoutSettings{}, err
	}
	settings.Assigned = 1
	if settings.Mode != "local" && settings.Mode != "remote" {
		settings.Reason = `monero.mode must be "local" or "remote" (got "` + settings.Mode + `").`
		return settings, nil
	}
	settings.ViewKey, err = payoutScalar(root, "monero.view_key", "")
	if err != nil {
		return MoneroPayoutSettings{}, err
	}
	settings.ScanHeight, err = payoutScalar(root, "monero.payout_scan_height", "auto")
	if err != nil {
		return MoneroPayoutSettings{}, err
	}
	settings.Enabled = "false"
	settings.Assigned = 4
	if settings.ViewKey == "" {
		return settings, nil
	}
	if settings.Mode != "local" {
		settings.Reason = `monero.view_key is set but monero.mode is "` + settings.Mode + `". On-chain payout confirmation scans against the LOCAL node only — a remote/third-party daemon changes the trust story. Unset monero.view_key, or switch to a local node.`
		return settings, nil
	}
	if !payoutKey(settings.ViewKey) {
		settings.Reason = "monero.view_key must be the 64-character hex SECRET VIEW KEY for monero.wallet_address (Monero GUI: Settings › Wallet › Show seed & keys › 'Secret view key'; monero-wallet-cli: viewkey). See " + docsURL + "/docs/dashboard.md#getting-your-view-keys. Got " + strconv.Itoa(len(settings.ViewKey)) + " chars."
		return settings, nil
	}
	if settings.ScanHeight != "" && settings.ScanHeight != "auto" && !decimalDigits(settings.ScanHeight) {
		settings.Reason = `monero.payout_scan_height must be "auto" or a block height (integer).`
		return settings, nil
	}
	settings.Enabled = "true"
	return settings, nil
}

func ParseTariPayoutSettings(raw []byte, mode, docsURL string) (TariPayoutSettings, error) {
	root, err := payoutDocument(raw)
	if err != nil || !payoutASCII(mode) || !payoutASCII(docsURL) {
		return TariPayoutSettings{}, ErrUnsupportedValidation
	}
	settings := TariPayoutSettings{Enabled: "false"}
	settings.ViewKey, err = payoutScalar(root, "tari.view_key", "")
	if err != nil {
		return TariPayoutSettings{}, err
	}
	settings.SpendPublicKey, err = payoutScalar(root, "tari.spend_public_key", "")
	if err != nil {
		return TariPayoutSettings{}, err
	}
	settings.Birthday, err = payoutScalar(root, "tari.payout_scan_birthday", "auto")
	if err != nil {
		return TariPayoutSettings{}, err
	}
	if settings.ViewKey == "" {
		return settings, nil
	}
	if mode != "local" {
		settings.Reason = `tari.view_key is set but tari.mode is "` + mode + `". Payout confirmation scans the LOCAL Tari node, so it needs tari.mode: local — unset tari.view_key, or use a local Tari node.`
		return settings, nil
	}
	if !payoutKey(settings.ViewKey) {
		settings.Reason = "tari.view_key must be the 64-character hex PRIVATE VIEW KEY for the Tari payout address (Tari Universe: 'view_private_key_hex' in config_wallet.json; minotari_console_wallet: export-view-key-and-spend-key). See " + docsURL + "/docs/dashboard.md#getting-your-view-keys. Got " + strconv.Itoa(len(settings.ViewKey)) + " chars."
	}
	return settings, nil
}

func ValidatePayoutBirthday(birthday, today string) (string, error) {
	if !payoutASCII(birthday) || !canonicalSignedInteger(today) {
		return "", ErrUnsupportedValidation
	}
	current, err := strconv.ParseInt(today, 10, 64)
	if err != nil {
		return "", ErrUnsupportedValidation
	}
	if birthday == "" || birthday == "auto" {
		return "", nil
	}
	if !decimalDigits(birthday) {
		return `tari.payout_scan_birthday must be "auto" or DAYS SINCE 2022-01-01 (Tari's wallet birthday; Tari Universe's wallet_birthday works as-is), NOT a block height. Got "` + birthday + `".`, nil
	}
	if len(birthday) <= 5 && current >= 0 {
		value, parseErr := strconv.ParseUint(birthday, 10, 64)
		if parseErr == nil && value <= uint64(current) {
			return "", nil
		}
	}
	return `tari.payout_scan_birthday must be days since 2022-01-01 (Tari's wallet birthday), no later than today (` + today + `). Got "` + birthday + `"; a days-since-1970 value is too large.`, nil
}

func payoutDocument(raw []byte) (node, error) {
	document, err := ParseDocument(raw)
	if err != nil || document == nil || duplicateError(document.root, "") != "" {
		return node{}, ErrUnsupportedValidation
	}
	return document.root, nil
}

func payoutScalar(root node, path, fallback string) (string, error) {
	value, err := getStringPath(root, path)
	if err != nil || value.object != nil || value.array != nil {
		return "", ErrUnsupportedValidation
	}
	result, err := networkSettingsScalar(root, path, node{value: fallback}, false)
	if err != nil {
		return "", ErrUnsupportedValidation
	}
	if !isNull(value) {
		switch typed := value.value.(type) {
		case string, bool:
		case json.Number:
			if !validJQInteger(typed.String()) {
				return "", ErrUnsupportedValidation
			}
		default:
			return "", ErrUnsupportedValidation
		}
	}
	if !payoutASCII(result) {
		return "", ErrUnsupportedValidation
	}
	return result, nil
}

func payoutASCII(value string) bool {
	for index := 0; index < len(value); index++ {
		if value[index] < 0x20 || value[index] > 0x7e {
			return false
		}
	}
	return true
}

func payoutKey(value string) bool {
	if len(value) != 64 {
		return false
	}
	return strings.IndexFunc(value, func(current rune) bool {
		return current < '0' || current > '9' && current < 'a' || current > 'f'
	}) == -1
}

func canonicalSignedInteger(value string) bool {
	if value == "0" {
		return true
	}
	if strings.HasPrefix(value, "-") {
		value = value[1:]
	}
	return len(value) > 0 && value[0] >= '1' && value[0] <= '9' && decimalDigits(value)
}
