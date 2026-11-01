package config

import (
	"errors"
	"strings"
	"testing"
)

func TestValidateInputOrder(t *testing.T) {
	tests := []struct {
		name        string
		raw         string
		stage       string
		reason      string
		unsupported bool
	}{
		{"valid", `{}`, "ok", "", false},
		{"syntax", `{`, "document", "not valid JSON", false},
		{"document before webhooks", `{"a":0,"a":1,"notifications":{"webhooks":false}}`, "document", `duplicate key "a" at the top level (path a)`, false},
		{"placeholder before controls", `{"value":"YOUR_secret\n"}`, "document", "placeholder value at value", false},
		{"webhooks before controls", `{"notifications":{"webhooks":false},"value":"bad\n"}`, "webhooks", "notifications.webhooks must be an array of URL strings.", false},
		{"webhook member", `{"notifications":{"webhooks":["https://example",null]}}`, "webhooks", "notifications.webhooks[1] must be a URL string; null and other non-string members are not allowed.", false},
		{"control value", `{"bad\nkey":"clean","value":"bad\n"}`, "controls", "control-character", false},
		{"control key ignored", `{"bad\nkey":"clean"}`, "ok", "", false},
		{"unsupported webhook root", `{"notifications":false}`, "", "", true},
		{"unsupported surrogate", `"\ud83d\ude00"`, "", "", true},
		{"unsupported depth", strings.Repeat("[", 129) + "0" + strings.Repeat("]", 129), "", "", true},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			stage, reason, err := ValidateInput([]byte(test.raw))
			if stage != test.stage || reason != test.reason || errors.Is(err, ErrUnsupportedInputValidation) != test.unsupported {
				t.Fatalf("ValidateInput() = %q, %q, %v", stage, reason, err)
			}
		})
	}
}
