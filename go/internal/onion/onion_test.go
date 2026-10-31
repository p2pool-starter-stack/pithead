package onion

import "testing"

func TestMissing(t *testing.T) {
	for _, test := range []struct {
		value string
		want  bool
	}{
		{"", true},
		{"placeholder", true},
		{"placeholder\n", false},
		{" placeholder", false},
		{"example.onion", false},
	} {
		if got := Missing(test.value); got != test.want {
			t.Errorf("Missing(%q) = %t, want %t", test.value, got, test.want)
		}
	}
}

func TestStatus(t *testing.T) {
	for _, test := range []struct {
		name, program, address, auth, want string
	}{
		{"empty", "./pithead", "", "true", ""},
		{"placeholder", "./pithead", "placeholder", "true", ""},
		{"login", "./pithead", "example.onion", "false", "http://example.onion (login required)"},
		{"client auth", "pit head", "example.onion", "true", "http://example.onion (client-auth ON + login; get your client key with 'pit head onion-client-key')"},
	} {
		t.Run(test.name, func(t *testing.T) {
			if got := Status(test.program, test.address, test.auth); got != test.want {
				t.Fatalf("Status() = %q, want %q", got, test.want)
			}
		})
	}
}
