package config

import (
	"errors"
	"testing"
)

func TestMaskConfig(t *testing.T) {
	paths := []byte(`[["dashboard","auth","password"],["monero","node_password"],["missing","value"]]`)
	for _, test := range []struct {
		name, raw, want string
		unsupported     bool
	}{
		{
			"all masks",
			`{"dashboard":{"auth":{"password":"secret"},"workers":[{"name":"old","token":"t","api_token":0},null]},"monero":{"node_password":false},"workers":{"list":[{"token":"","api_token":"a","tail":true},{}]},"notifications":{"webhooks":["https://hook",null,false,"",0,[],{}]},"last":"ok"}`,
			"{\n  \"dashboard\": {\n    \"auth\": {\n      \"password\": {\n        \"__secret__\": true\n      }\n    },\n    \"workers\": [\n      {\n        \"name\": \"old\",\n        \"token\": {\n          \"__secret__\": true\n        },\n        \"api_token\": {\n          \"__secret__\": true\n        }\n      },\n      null\n    ]\n  },\n  \"monero\": {\n    \"node_password\": false\n  },\n  \"workers\": {\n    \"list\": [\n      {\n        \"token\": \"\",\n        \"api_token\": {\n          \"__secret__\": true\n        },\n        \"tail\": true\n      },\n      {}\n    ]\n  },\n  \"notifications\": {\n    \"webhooks\": [\n      {\n        \"__secret__\": true,\n        \"slot\": 0\n      },\n      null,\n      false,\n      \"\",\n      {\n        \"__secret__\": true,\n        \"slot\": 4\n      },\n      {\n        \"__secret__\": true,\n        \"slot\": 5\n      },\n      {\n        \"__secret__\": true,\n        \"slot\": 6\n      }\n    ]\n  },\n  \"last\": \"ok\"\n}\n",
			false,
		},
		{"empty fixed values", `{"dashboard":{"auth":{"password":null}},"monero":{"node_password":""}}`, "{\n  \"dashboard\": {\n    \"auth\": {\n      \"password\": null\n    }\n  },\n  \"monero\": {\n    \"node_password\": \"\"\n  }\n}\n", false},
		{"wrong optional containers", `{"dashboard":[],"workers":false,"notifications":{"webhooks":{}}}`, "{\n  \"dashboard\": [],\n  \"workers\": false,\n  \"notifications\": {\n    \"webhooks\": {}\n  }\n}\n", false},
		{"invalid worker entry", `{"workers":{"list":[1]}}`, "", true},
		{"float fallback", `{"value":1.5}`, "", true},
		{"duplicate fallback", `{"workers":{},"workers":{}}`, "", true},
	} {
		t.Run(test.name, func(t *testing.T) {
			got, err := MaskConfig([]byte(test.raw), paths)
			if string(got) != test.want || errors.Is(err, ErrUnsupportedMaskedConfig) != test.unsupported {
				t.Fatalf("MaskConfig() = %q, %v", got, err)
			}
		})
	}
}

func TestMaskConfigPathRefusals(t *testing.T) {
	for _, paths := range []string{`{}`, `[[]]`, `[[0]]`, `[["value"],["value"]]x`, `[["value"],["value",1]]`} {
		if output, err := MaskConfig([]byte(`{"value":"secret"}`), []byte(paths)); output != nil || !errors.Is(err, ErrUnsupportedMaskedConfig) {
			t.Fatalf("paths %q = %q, %v", paths, output, err)
		}
	}
}
