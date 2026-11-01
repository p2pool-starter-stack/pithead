package config

import "testing"

func TestCaddyBindAddresses(t *testing.T) {
	for _, test := range []struct {
		name       string
		bridges    string
		prefix     string
		candidates []string
		want       string
	}{
		{"empty", " 172.28.17.1 ", "172.28.0", nil, "127.0.0.1 ::1"},
		{"filters", " 172.28.17.1 172.28.88.1 ", "172.28.0", []string{"172.28.1.2", "172.28.17.1", "172.28.0.1", "host", "fe80::1"}, "172.28.1.2 fe80::1 127.0.0.1 ::1"},
		{"original-case-rules", " ", "", []string{"", ".", "1..2", "123", "v6:name", "name", "1.2.3.4x"}, ". 1..2 123 v6:name 127.0.0.1 ::1"},
		{"padded-substring", " 172.28.0.10 ", "", []string{"172.28.0.1", "172.28.0.10"}, "172.28.0.1 127.0.0.1 ::1"},
		{"order-and-duplicates", " ", "", []string{"fd00::2", "172.28.0.2", "fd00::2"}, "fd00::2 172.28.0.2 fd00::2 127.0.0.1 ::1"},
	} {
		t.Run(test.name, func(t *testing.T) {
			if got := CaddyBindAddresses(test.bridges, test.prefix, test.candidates); got != test.want {
				t.Fatalf("CaddyBindAddresses() = %q; want %q", got, test.want)
			}
		})
	}
}
