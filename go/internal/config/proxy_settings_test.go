package config

import (
	"errors"
	"strings"
	"testing"
)

func TestParseProxySettingsDefaultsAndValues(t *testing.T) {
	tests := []struct {
		name string
		raw  string
		want ProxySettings
	}{
		{"defaults", `{}`, ProxySettings{Assigned: 3, Values: [3]string{"", "false", "0"}}},
		{"values", `{"p2pool":{"stratum_password":"Rig_1:@-.","stratum_tls":"YES"},"proxy":{"donate_level":"099"}}`, ProxySettings{Assigned: 3, Values: [3]string{"Rig_1:@-.", "true", "099"}}},
		{"false defaults", `{"p2pool":{"stratum_password":false,"stratum_tls":false},"proxy":{"donate_level":false}}`, ProxySettings{Assigned: 3, Values: [3]string{"", "false", "0"}}},
		{"arbitrary zero digits", `{"proxy":{"donate_level":"` + strings.Repeat("0", 256) + `"}}`, ProxySettings{Assigned: 3, Values: [3]string{"", "false", strings.Repeat("0", 256)}}},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			got, err := ParseProxySettings([]byte(test.raw))
			if err != nil || got != test.want {
				t.Fatalf("ParseProxySettings() = %#v, %v; want %#v, nil", got, err, test.want)
			}
		})
	}
}

func TestParseProxySettingsVerdictsAndPrecedence(t *testing.T) {
	passwordReason := `p2pool.stratum_password must be "auto", empty, or 1–128 chars of letters, digits, and . _ : @ - (no spaces or quotes).`
	tests := []struct {
		name string
		raw  string
		want ProxySettings
	}{
		{"password characters", `{"p2pool":{"stratum_password":"bad pass","stratum_tls":[]}}`, ProxySettings{Assigned: 1, Values: [3]string{"bad pass"}, Reason: passwordReason}},
		{"password length", `{"p2pool":{"stratum_password":"` + strings.Repeat("a", 129) + `"}}`, ProxySettings{Assigned: 1, Values: [3]string{strings.Repeat("a", 129)}, Reason: passwordReason}},
		{"donate nondigits", `{"proxy":{"donate_level":"auto"}}`, ProxySettings{Assigned: 3, Values: [3]string{"", "false", "auto"}, Reason: `proxy.donate_level must be an integer 0–99 (percent); default 0 (got "auto").`}},
		{"donate upper bound", `{"proxy":{"donate_level":100}}`, ProxySettings{Assigned: 3, Values: [3]string{"", "false", "100"}, Reason: `proxy.donate_level must be an integer 0–99 (percent); default 0 (got "100").`}},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			got, err := ParseProxySettings([]byte(test.raw))
			if err != nil || got != test.want {
				t.Fatalf("ParseProxySettings() = %#v, %v; want %#v, nil", got, err, test.want)
			}
		})
	}
}

func TestParseProxySettingsRejectsUnsupportedInput(t *testing.T) {
	tests := map[string]string{
		"invalid JSON":          `{`,
		"duplicate":             `{"proxy":{},"proxy":{}}`,
		"scalar parent":         `{"p2pool":4}`,
		"auto password":         `{"p2pool":{"stratum_password":"auto"}}`,
		"compound password":     `{"p2pool":{"stratum_password":[]}}`,
		"control password":      `{"p2pool":{"stratum_password":"bad\npass"}}`,
		"compound TLS":          `{"p2pool":{"stratum_tls":{}}}`,
		"compound donate":       `{"proxy":{"donate_level":[]}}`,
		"decimal donate":        `{"proxy":{"donate_level":1.0}}`,
		"unsafe integer donate": `{"proxy":{"donate_level":"9223372036854775808"}}`,
	}
	for name, raw := range tests {
		t.Run(name, func(t *testing.T) {
			got, err := ParseProxySettings([]byte(raw))
			if got != (ProxySettings{}) || !errors.Is(err, ErrUnsupportedValidation) {
				t.Fatalf("ParseProxySettings() = %#v, %v; want zero, unsupported", got, err)
			}
		})
	}
}
