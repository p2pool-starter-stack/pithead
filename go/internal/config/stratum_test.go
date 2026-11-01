package config

import (
	"errors"
	"strings"
	"testing"
)

func TestParseStratumEndpointValidValues(t *testing.T) {
	tests := []struct {
		name string
		raw  string
		bind string
		port string
	}{
		{"defaults", `{}`, "0.0.0.0", "3333"},
		{"false defaults", `{"p2pool":{"stratum_bind":false,"stratum_port":false}}`, "0.0.0.0", "3333"},
		{"leading zeros", `{"p2pool":{"stratum_bind":"000.001.255.099","stratum_port":"00001"}}`, "000.001.255.099", "00001"},
		{"upper bounds", `{"p2pool":{"stratum_bind":"255.255.255.255","stratum_port":65535}}`, "255.255.255.255", "65535"},
		{"loopback custom", `{"p2pool":{"stratum_bind":"127.0.0.1","stratum_port":"4444"}}`, "127.0.0.1", "4444"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			got, err := ParseStratumEndpoint([]byte(test.raw))
			want := StratumEndpoint{Stage: "ok", Bind: test.bind, Port: test.port}
			if err != nil || got != want {
				t.Fatalf("ParseStratumEndpoint() = %#v, %v; want %#v, nil", got, err, want)
			}
		})
	}
}

func TestParseStratumEndpointBindErrorsPrecedePortRead(t *testing.T) {
	tests := []string{
		"not-an-ip",
		"1.2.3",
		"1.2.3.4.5",
		"1.2.3.256",
		"1.2.3.0000",
		"1.2.3.-1",
		" 1.2.3.4",
		"１.2.3.4",
	}
	for _, bind := range tests {
		raw := `{"p2pool":{"stratum_bind":"` + bind + `","stratum_port":[]}}`
		got, err := ParseStratumEndpoint([]byte(raw))
		want := StratumEndpoint{
			Stage:  "bind-error",
			Bind:   bind,
			Reason: `p2pool.stratum_bind must be an IPv4 address like "0.0.0.0", "127.0.0.1", or your LAN IP (got "` + bind + `").`,
		}
		if err != nil || got != want {
			t.Errorf("bind %q: got %#v, %v; want %#v, nil", bind, got, err, want)
		}
	}
}

func TestParseStratumEndpointPortErrors(t *testing.T) {
	tests := []string{"", "0", "00000", "65536", "123456", "1a", "-1", "true"}
	for _, port := range tests {
		value := `"` + port + `"`
		if port == "true" {
			value = port
		}
		raw := `{"p2pool":{"stratum_bind":"127.0.0.1","stratum_port":` + value + `}}`
		got, err := ParseStratumEndpoint([]byte(raw))
		want := StratumEndpoint{
			Stage:  "port-error",
			Bind:   "127.0.0.1",
			Port:   port,
			Reason: `p2pool.stratum_port must be an integer between 1 and 65535 (got "` + port + `").`,
		}
		if err != nil || got != want {
			t.Errorf("port %q: got %#v, %v; want %#v, nil", port, got, err, want)
		}
	}
}

func TestParseStratumEndpointRejectsUnsupportedInput(t *testing.T) {
	secret := "operator-secret"
	tests := map[string]string{
		"invalid JSON":   `{`,
		"duplicate":      `{"p2pool":{},"p2pool":{}}`,
		"scalar parent":  `{"p2pool":4}`,
		"compound bind":  `{"p2pool":{"stratum_bind":[]}}`,
		"compound port":  `{"p2pool":{"stratum_port":{}}}`,
		"control bind":   `{"p2pool":{"stratum_bind":"` + secret + `\n"}}`,
		"decimal port":   `{"p2pool":{"stratum_port":3333.0}}`,
		"unsafe integer": `{"p2pool":{"stratum_port":9007199254740992}}`,
	}
	for name, raw := range tests {
		t.Run(name, func(t *testing.T) {
			got, err := ParseStratumEndpoint([]byte(raw))
			if got != (StratumEndpoint{}) || !errors.Is(err, ErrUnsupportedValidation) {
				t.Fatalf("ParseStratumEndpoint() = %#v, %v; want zero, unsupported", got, err)
			}
			if strings.Contains(err.Error(), secret) {
				t.Fatalf("error exposes input: %q", err)
			}
		})
	}
}
