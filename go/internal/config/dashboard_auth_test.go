package config

import (
	"errors"
	"strings"
	"testing"
)

func TestParseDashboardAuth(t *testing.T) {
	tests := []struct {
		name string
		raw  string
		want DashboardAuth
	}{
		{"defaults", `{}`, DashboardAuth{Username: "admin"}},
		{"false defaults", `{"dashboard":{"auth":{"username":false,"password":false}}}`, DashboardAuth{Username: "admin"}},
		{"valid", `{"dashboard":{"auth":{"username":"miner_1@example.test","password":"long passphrase!"}}}`, DashboardAuth{Username: "miner_1@example.test", Password: "long passphrase!"}},
		{"empty skips username", `{"dashboard":{"auth":{"username":"bad user","password":""}}}`, DashboardAuth{Username: "bad user"}},
		{"username before password", `{"dashboard":{"auth":{"username":"bad user","password":"short"}}}`, DashboardAuth{Username: "bad user", Password: "short", Reason: `dashboard.auth.username must be 1–64 chars of letters, digits, and . _ @ - (got "bad user").`}},
		{"password length", `{"dashboard":{"auth":{"password":"short"}}}`, DashboardAuth{Username: "admin", Password: "short", Reason: `dashboard.auth.password must be 8–128 printable characters with no double-quotes.`}},
		{"password quote", `{"dashboard":{"auth":{"password":"1234567\""}}}`, DashboardAuth{Username: "admin", Password: `1234567"`, Reason: `dashboard.auth.password must be 8–128 printable characters with no double-quotes.`}},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			got, err := ParseDashboardAuth([]byte(test.raw))
			if err != nil || got != test.want {
				t.Fatalf("ParseDashboardAuth() = %#v, %v; want %#v, nil", got, err, test.want)
			}
		})
	}
}

func TestParseDashboardAuthRejectsUnsupportedInput(t *testing.T) {
	tests := map[string]string{
		"invalid JSON":       `{`,
		"duplicate":          `{"dashboard":{"auth":{"password":"first","password":"second"}}}`,
		"compound username":  `{"dashboard":{"auth":{"username":[],"password":"longenough"}}}`,
		"compound password":  `{"dashboard":{"auth":{"password":{}}}}`,
		"control password":   `{"dashboard":{"auth":{"password":"long\npassword"}}}`,
		"short non-ASCII":    `{"dashboard":{"auth":{"password":"ä"}}}`,
		"non-ASCII password": `{"dashboard":{"auth":{"password":"longpassphräse"}}}`,
		"non-ASCII username": `{"dashboard":{"auth":{"username":"opérateur","password":"longpassphrase"}}}`,
	}
	for name, raw := range tests {
		t.Run(name, func(t *testing.T) {
			got, err := ParseDashboardAuth([]byte(raw))
			if got != (DashboardAuth{}) || !errors.Is(err, ErrUnsupportedValidation) {
				t.Fatalf("ParseDashboardAuth() = %#v, %v; want zero, unsupported", got, err)
			}
		})
	}
}

func TestParseDashboardPolicy(t *testing.T) {
	weakReason := "dashboard.auth.password contains a well-known weak pattern — choose a real passphrase (16+ characters)."
	tests := []struct {
		name  string
		raw   string
		input DashboardPolicyInput
		want  DashboardPolicy
	}{
		{"defaults", `{}`, DashboardPolicyInput{}, DashboardPolicy{Assigned: 3, Values: [3]string{"false", "false", "false"}}},
		{"onion defaults client auth", `{"dashboard":{"onion":{"enabled":true}}}`, DashboardPolicyInput{Password: "a strong passphrase"}, DashboardPolicy{Assigned: 3, Values: [3]string{"true", "true", "false"}}},
		{"onion disabled ignores client auth", `{"dashboard":{"onion":{"enabled":false,"client_auth":[]}}}`, DashboardPolicyInput{}, DashboardPolicy{Assigned: 3, Values: [3]string{"false", "false", "false"}}},
		{"onion empty", `{"dashboard":{"onion":{"enabled":true}}}`, DashboardPolicyInput{}, DashboardPolicy{Assigned: 2, Values: [3]string{"true", "true", ""}, Reason: "dashboard.onion.enabled is true but dashboard.auth.password is empty. Publishing the dashboard as a Tor onion exposes a control panel at a stable address — it must sit behind a login. Set a strong dashboard.auth.password (16+ characters) and re-run."}},
		{"onion short before control", `{"dashboard":{"onion":{"enabled":true},"control":{"enabled":[]}}}`, DashboardPolicyInput{Password: "shortpass"}, DashboardPolicy{Assigned: 2, Values: [3]string{"true", "true", ""}, Reason: "dashboard.auth.password must be at least 16 characters when dashboard.onion.enabled is true (a published .onion is online-brute-forceable and per-IP throttling is meaningless over Tor). Use a passphrase."}},
		{"onion repeated", `{"dashboard":{"onion":{"enabled":true}}}`, DashboardPolicyInput{Password: strings.Repeat("a", 16)}, DashboardPolicy{Assigned: 2, Values: [3]string{"true", "true", ""}, Reason: "dashboard.auth.password is a single repeated character — choose a real passphrase."}},
		{"onion weak", `{"dashboard":{"onion":{"enabled":true}}}`, DashboardPolicyInput{Password: "xxCHANGEMEyyzzzz"}, DashboardPolicy{Assigned: 2, Values: [3]string{"true", "true", ""}, Reason: weakReason}},
		{"control needs password", `{"dashboard":{"control":{"enabled":true}}}`, DashboardPolicyInput{Program: "./pithead"}, DashboardPolicy{Assigned: 3, Values: [3]string{"false", "false", "true"}, Reason: "dashboard.control.enabled is true but dashboard.auth.password is empty. Config editing from the dashboard can change the payout wallet and run './pithead apply' — it must sit behind a login. Set dashboard.auth.password and re-run."}},
		{"control onion client auth", `{"dashboard":{"onion":{"enabled":true,"client_auth":false},"control":{"enabled":true}}}`, DashboardPolicyInput{Password: "a strong passphrase"}, DashboardPolicy{Assigned: 3, Values: [3]string{"true", "false", "true"}, Reason: "dashboard.control.enabled is true on a published onion (dashboard.onion.enabled) but dashboard.onion.client_auth is false. A root-capable config-mutation channel must not sit behind only a brute-forceable password on an anonymously-reachable .onion. Set dashboard.onion.client_auth: true (the default) and re-run."}},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			got, err := ParseDashboardPolicy([]byte(test.raw), test.input)
			if err != nil || got != test.want {
				t.Fatalf("ParseDashboardPolicy() = %#v, %v; want %#v, nil", got, err, test.want)
			}
		})
	}
}

func TestParseDashboardPolicyRejectsUnsupportedInput(t *testing.T) {
	tests := []struct {
		name  string
		raw   string
		input DashboardPolicyInput
	}{
		{"duplicate", `{"dashboard":{},"dashboard":{}}`, DashboardPolicyInput{}},
		{"compound onion", `{"dashboard":{"onion":{"enabled":[]}}}`, DashboardPolicyInput{}},
		{"compound client auth", `{"dashboard":{"onion":{"enabled":true,"client_auth":[]}}}`, DashboardPolicyInput{Password: "a strong passphrase"}},
		{"non-ASCII onion password", `{"dashboard":{"onion":{"enabled":true}}}`, DashboardPolicyInput{Password: "strong passphräse"}},
		{"control onion password", `{"dashboard":{"onion":{"enabled":true}}}`, DashboardPolicyInput{Password: "strong\npassphrase"}},
		{"compound control", `{"dashboard":{"control":{"enabled":[]}}}`, DashboardPolicyInput{}},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			got, err := ParseDashboardPolicy([]byte(test.raw), test.input)
			if got != (DashboardPolicy{}) || !errors.Is(err, ErrUnsupportedValidation) {
				t.Fatalf("ParseDashboardPolicy() = %#v, %v; want zero, unsupported", got, err)
			}
		})
	}
}
