package config

import (
	"errors"
	"testing"
)

func TestParseNetworkSettingsDefaults(t *testing.T) {
	got, err := ParseNetworkSettings([]byte(`{}`), NetworkSettingsInput{MoneroMode: "local", TariMode: "local"})
	want := NetworkSettings{
		Assigned: 12,
		Values: [12]string{
			"172.28.0.0/24", "172.28.0", "true", "false",
			"https://textexplore.tari.com/?json", "false",
			"", "", "", "", "", "mini",
		},
	}
	if err != nil || got != want {
		t.Fatalf("ParseNetworkSettings() = %#v, %v; want %#v, nil", got, err, want)
	}
}

func TestParseNetworkSettingsCustomAndRemoteValues(t *testing.T) {
	raw := []byte(`{
		"network":{"subnet":"010.020.030.0/24","tor_egress_firewall":"OFF"},
		"tor":{"auto_heal":"YES"},
		"tari":{"explorer_url":"https://explorer.example/?json","remote":{"host":"2001:db8::10","grpc_port":65535}},
		"p2pool":{"clearnet":1,"pool":"main"},
		"monero":{"remote":{"host":"node_example.test","rpc_port":18091,"zmq_port":"18093"}}
	}`)
	got, err := ParseNetworkSettings(raw, NetworkSettingsInput{MoneroMode: "remote", TariMode: "remote", ConfigPath: "config.json"})
	want := NetworkSettings{
		Assigned: 12,
		Values: [12]string{
			"010.020.030.0/24", "010.020.030", "false", "true",
			"https://explorer.example/?json", "true",
			"node_example.test", "18091", "18093", "2001:db8::10", "65535", "main",
		},
	}
	if err != nil || got != want {
		t.Fatalf("ParseNetworkSettings() = %#v, %v; want %#v, nil", got, err, want)
	}
}

func TestParseNetworkSettingsSubnetVerdictsPrecedeLaterReads(t *testing.T) {
	tests := []struct {
		name     string
		subnet   string
		assigned int
		reason   string
	}{
		{"shape", "172.28.0.0/16", 1, `network.subnet must be an X.Y.Z.0/24 block (got "172.28.0.0/16").`},
		{"IPv4", "172.999.0.0/24", 2, `network.subnet is not a valid IPv4 /24 (got "172.999.0.0/24").`},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			raw := `{"network":{"subnet":"` + test.subnet + `","tor_egress_firewall":[]}}`
			got, err := ParseNetworkSettings([]byte(raw), NetworkSettingsInput{})
			if err != nil || got.Assigned != test.assigned || got.Reason != test.reason {
				t.Fatalf("ParseNetworkSettings() = %#v, %v; want assigned %d, reason %q", got, err, test.assigned, test.reason)
			}
		})
	}
}

func TestParseNetworkSettingsRemoteVerdicts(t *testing.T) {
	tests := []struct {
		name   string
		raw    string
		input  NetworkSettingsInput
		reason string
	}{
		{
			"missing Monero host", `{}`,
			NetworkSettingsInput{MoneroMode: "remote", ConfigPath: "/tmp/config.json"},
			`monero.mode is "remote" but monero.remote.host is not set in /tmp/config.json.`,
		},
		{
			"invalid Monero host", `{"monero":{"remote":{"host":"bad host"}},"p2pool":{"pool":[]}}`,
			NetworkSettingsInput{MoneroMode: "remote"},
			`monero.remote.host must be a hostname or IP literal (letters, digits, and . : _ - only, ≤253 chars). Got "bad host".`,
		},
		{
			"Monero RPC leading zero", `{"monero":{"remote":{"host":"node","rpc_port":"08081"}}}`,
			NetworkSettingsInput{MoneroMode: "remote"},
			`monero.remote.rpc_port must be a TCP port 1–65535. Got "08081".`,
		},
		{
			"Monero ZMQ range", `{"monero":{"remote":{"host":"node","zmq_port":65536}}}`,
			NetworkSettingsInput{MoneroMode: "remote"},
			`monero.remote.zmq_port must be a TCP port 1–65535. Got "65536".`,
		},
		{
			"missing Tari host", `{}`,
			NetworkSettingsInput{TariMode: "remote", ConfigPath: "candidate.json"},
			`tari.mode is "remote" but tari.remote.host is not set in candidate.json.`,
		},
		{
			"invalid Tari host", `{"tari":{"remote":{"host":"bad/path"}}}`,
			NetworkSettingsInput{TariMode: "remote"},
			`tari.remote.host must be a hostname or IP literal (letters, digits, and . : _ - only, ≤253 chars). Got "bad/path".`,
		},
		{
			"Tari port leading zero", `{"tari":{"remote":{"host":"node","grpc_port":"08142"}}}`,
			NetworkSettingsInput{TariMode: "remote"},
			`tari.remote.grpc_port must be a TCP port 1–65535. Got "08142".`,
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			got, err := ParseNetworkSettings([]byte(test.raw), test.input)
			if err != nil || got.Assigned != 11 || got.Reason != test.reason {
				t.Fatalf("ParseNetworkSettings() = %#v, %v; want assigned 11, reason %q", got, err, test.reason)
			}
		})
	}
}

func TestParseNetworkSettingsSkipsLocalRemoteBranches(t *testing.T) {
	raw := []byte(`{
		"monero":{"remote":{"host":[],"rpc_port":{},"zmq_port":[]}},
		"tari":{"remote":{"host":{},"grpc_port":[]}},
		"p2pool":{"pool":"nano"}
	}`)
	got, err := ParseNetworkSettings(raw, NetworkSettingsInput{MoneroMode: "local", TariMode: "off"})
	if err != nil || got.Assigned != 12 || got.Reason != "" || got.Values[11] != "nano" {
		t.Fatalf("ParseNetworkSettings() = %#v, %v; want successful local settings", got, err)
	}
}

func TestParseNetworkSettingsPoolVerdict(t *testing.T) {
	got, err := ParseNetworkSettings([]byte(`{"p2pool":{"pool":"other"}}`), NetworkSettingsInput{})
	wantReason := `p2pool.pool must be "main", "mini", or "nano" (got "other").`
	if err != nil || got.Assigned != 12 || got.Values[11] != "other" || got.Reason != wantReason {
		t.Fatalf("ParseNetworkSettings() = %#v, %v; want assigned 12, reason %q", got, err, wantReason)
	}
}

func TestParseNetworkSettingsFalseAndNullDefaults(t *testing.T) {
	raw := []byte(`{
		"network":{"subnet":false,"tor_egress_firewall":false},
		"tor":{"auto_heal":null},
		"tari":{"explorer_url":false},
		"p2pool":{"clearnet":null,"pool":false}
	}`)
	got, err := ParseNetworkSettings(raw, NetworkSettingsInput{})
	if err != nil || got.Assigned != 12 {
		t.Fatal(got, err)
	}
	want := [6]string{"172.28.0.0/24", "172.28.0", "false", "false", "https://textexplore.tari.com/?json", "false"}
	if got.Values[0] != want[0] || got.Values[1] != want[1] || got.Values[2] != want[2] || got.Values[3] != want[3] || got.Values[4] != want[4] || got.Values[5] != want[5] || got.Values[11] != "mini" {
		t.Fatalf("defaults = %#v", got.Values)
	}
}

func TestParseNetworkSettingsRejectsUnsupportedInput(t *testing.T) {
	tests := map[string]string{
		"invalid JSON":        `{`,
		"duplicate":           `{"network":{},"network":{}}`,
		"scalar parent":       `{"network":4}`,
		"compound subnet":     `{"network":{"subnet":[]}}`,
		"control value":       `{"network":{"subnet":"172.28.0.0/24\n"}}`,
		"compound flag":       `{"network":{"tor_egress_firewall":{}}}`,
		"decimal remote port": `{"monero":{"remote":{"host":"node","rpc_port":18081.0}}}`,
	}
	for name, raw := range tests {
		t.Run(name, func(t *testing.T) {
			input := NetworkSettingsInput{}
			if name == "decimal remote port" {
				input.MoneroMode = "remote"
			}
			got, err := ParseNetworkSettings([]byte(raw), input)
			if got != (NetworkSettings{}) || !errors.Is(err, ErrUnsupportedValidation) {
				t.Fatalf("ParseNetworkSettings() = %#v, %v; want zero, unsupported", got, err)
			}
		})
	}
}
