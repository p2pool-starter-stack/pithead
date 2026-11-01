package config

import (
	"errors"
	"testing"
)

func TestPersistNodeCredentials(t *testing.T) {
	for _, test := range []struct {
		name, raw, want string
		unsupported     bool
	}{
		{"append monero", `{"first":1}`, "{\n  \"first\": 1,\n  \"monero\": {\n    \"node_username\": \"user\",\n    \"node_password\": \"p\\n\\u0001é\"\n  }\n}\n", false},
		{"replace in place", `{"monero":{"mode":"local","node_password":"old","node_username":"old"},"last":true}`, "{\n  \"monero\": {\n    \"mode\": \"local\",\n    \"node_password\": \"p\\n\\u0001é\",\n    \"node_username\": \"user\"\n  },\n  \"last\": true\n}\n", false},
		{"null monero", `{"monero":null}`, "{\n  \"monero\": {\n    \"node_username\": \"user\",\n    \"node_password\": \"p\\n\\u0001é\"\n  }\n}\n", false},
		{"false container", `{"monero":false}`, "", true},
		{"float fallback", `{"value":1.5}`, "", true},
		{"duplicate fallback", `{"monero":{},"monero":{}}`, "", true},
	} {
		t.Run(test.name, func(t *testing.T) {
			got, err := PersistNodeCredentials([]byte(test.raw), "user", "p\n\x01é")
			if string(got) != test.want || errors.Is(err, ErrUnsupportedPersistence) != test.unsupported {
				t.Fatalf("PersistNodeCredentials() = %q, %v", got, err)
			}
		})
	}
}

func TestApplyApplianceDefaults(t *testing.T) {
	defaults := []byte(`{"tor":{"auto_heal":true},"dashboard":{"control":{"enabled":true}}}`)
	for _, test := range []struct {
		name, raw, want string
		unsupported     bool
	}{
		{"both defaults", `{"dashboard":{"auth":{"password":"secret"}}}`, "{\n  \"dashboard\": {\n    \"auth\": {\n      \"password\": \"secret\"\n    },\n    \"control\": {\n      \"enabled\": true\n    }\n  },\n  \"tor\": {\n    \"auto_heal\": true\n  }\n}\n", false},
		{"false preserved", `{"tor":{"auto_heal":false},"dashboard":{"auth":{"password":"secret"},"control":{"enabled":false}}}`, "{\n  \"tor\": {\n    \"auto_heal\": false\n  },\n  \"dashboard\": {\n    \"auth\": {\n      \"password\": \"secret\"\n    },\n    \"control\": {\n      \"enabled\": false\n    }\n  }\n}\n", false},
		{"empty password", `{"dashboard":{"auth":{"password":""}}}`, "{\n  \"dashboard\": {\n    \"auth\": {\n      \"password\": \"\"\n    }\n  },\n  \"tor\": {\n    \"auto_heal\": true\n  }\n}\n", false},
		{"numeric password", `{"dashboard":{"auth":{"password":0}}}`, "{\n  \"dashboard\": {\n    \"auth\": {\n      \"password\": 0\n    },\n    \"control\": {\n      \"enabled\": true\n    }\n  },\n  \"tor\": {\n    \"auto_heal\": true\n  }\n}\n", false},
		{"object password", `{"dashboard":{"auth":{"password":{}}}}`, "{\n  \"dashboard\": {\n    \"auth\": {\n      \"password\": {}\n    },\n    \"control\": {\n      \"enabled\": true\n    }\n  },\n  \"tor\": {\n    \"auto_heal\": true\n  }\n}\n", false},
		{"false tor container", `{"tor":false}`, "", true},
		{"float fallback", `{"value":1.5}`, "", true},
	} {
		t.Run(test.name, func(t *testing.T) {
			got, err := ApplyApplianceDefaults([]byte(test.raw), defaults)
			if string(got) != test.want || errors.Is(err, ErrUnsupportedPersistence) != test.unsupported {
				t.Fatalf("ApplyApplianceDefaults() = %q, %v", got, err)
			}
		})
	}
}
