package config

import "errors"

var ErrUnsupportedInputValidation = errors.New("unsupported config input validation")

func ValidateInput(raw []byte) (string, string, error) {
	document, err := ParseDocument(raw)
	if errors.Is(err, ErrUnsupportedDocument) {
		return "", "", ErrUnsupportedInputValidation
	}
	if err != nil {
		return "document", "not valid JSON", nil
	}
	if reason := document.ValidationError(false); reason != "" {
		return "document", reason, nil
	}
	reason, warning, err := validateWebhooks(document.root)
	if err != nil || warning {
		return "", "", ErrUnsupportedInputValidation
	}
	if reason != "" {
		return "webhooks", reason, nil
	}
	if hasControlValue(document.root) {
		return "controls", "control-character", nil
	}
	return "ok", "", nil
}
