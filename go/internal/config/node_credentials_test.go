package config

import (
	"errors"
	"testing"
)

func TestParseNodeCredentials(t *testing.T) {
	tests := []struct {
		name, raw, mode, user string
		want                  NodeCredentials
	}{
		{name: "defaults local", raw: `{}`, mode: "local", want: NodeCredentials{GenerateUser: true, GeneratePass: true}},
		{name: "placeholders", raw: `{"monero":{"node_password":"create_a_password_for_node"}}`, mode: "local", user: placeholderNodeUser, want: NodeCredentials{User: placeholderNodeUser, Pass: placeholderNodePass, GenerateUser: true, GeneratePass: true}},
		{name: "values", raw: `{"monero":{"node_password":"secret\n"}}`, mode: "local", user: "alice", want: NodeCredentials{User: "alice", Pass: "secret"}},
		{name: "remote empty", raw: `{}`, mode: "remote", want: NodeCredentials{}},
		{name: "false and null", raw: `{"monero":{"node_password":null}}`, mode: "local", want: NodeCredentials{GenerateUser: true, GeneratePass: true}},
		{name: "scalar projections", raw: `{"monero":{"node_password":42}}`, mode: "local", user: "true", want: NodeCredentials{User: "true", Pass: "42"}},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			got, err := ParseNodeCredentials([]byte(test.raw), test.mode, test.user)
			if err != nil || got != test.want {
				t.Fatalf("ParseNodeCredentials() = %#v, %v; want %#v, nil", got, err, test.want)
			}
		})
	}
}

func TestParseNodeCredentialsRejectsUnsupportedInput(t *testing.T) {
	for _, raw := range []string{`[]`, `{"monero":{"node_password":{}}}`, `{"monero":{"node_password":1.5}}`, `{"monero":{"node_password":"x\u0000y"}}`} {
		got, err := ParseNodeCredentials([]byte(raw), "local", "user")
		if got != (NodeCredentials{}) || !errors.Is(err, ErrUnsupportedValidation) {
			t.Fatalf("ParseNodeCredentials(%q) = %#v, %v", raw, got, err)
		}
	}
}
