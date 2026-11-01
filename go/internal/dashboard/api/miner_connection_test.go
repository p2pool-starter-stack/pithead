package api

import (
	"encoding/json"
	"reflect"
	"testing"
)

func TestBuildMinerConnection(t *testing.T) {
	got, err := BuildMinerConnection(MinerConnectionInput{
		HostIP: "pithead.local", Bind: "0.0.0.0", DetectedHostIPv4: "192.0.2.8", Port: json.RawMessage("4444"),
		Password: "secret", TLS: "true", Fingerprint: "abcd",
	})
	if err != nil {
		t.Fatal(err)
	}
	want := map[string]any{
		"url": "stratum+ssl://192.0.2.8:4444", "local_only": false,
		"password_set": true, "password": "secret", "tls": true, "fingerprint": "abcd",
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("got %#v, want %#v", got, want)
	}
}

func TestBuildMinerConnectionPythonHostRules(t *testing.T) {
	tests := []struct {
		name  string
		input MinerConnectionInput
		url   string
		local bool
	}{
		{"literal host", MinerConnectionInput{HostIP: "192.0.2.8", Bind: "0.0.0.0", DetectedHostIPv4: "192.0.2.9"}, "stratum+tcp://192.0.2.8:3333", false},
		{"empty bind", MinerConnectionInput{HostIP: "192.0.2.8"}, "stratum+tcp://:3333", false},
		{"explicit bind", MinerConnectionInput{HostIP: "192.0.2.8", Bind: "192.0.2.9"}, "stratum+tcp://192.0.2.9:3333", false},
		{"loopback", MinerConnectionInput{HostIP: "192.0.2.8", Bind: "127.0.0.1"}, "stratum+tcp://127.0.0.1:3333", true},
		{"ipv6", MinerConnectionInput{HostIP: "2001:db8::1", Bind: "0.0.0.0"}, "stratum+tcp://[2001:db8::1]:3333", false},
		{"duplicate detection", MinerConnectionInput{HostIP: "pithead.local", Bind: "0.0.0.0", DetectedHostIPv4: "pithead.local"}, "stratum+tcp://pithead.local:3333", false},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			got, err := BuildMinerConnection(test.input)
			if err != nil {
				t.Fatal(err)
			}
			if got["url"] != test.url || got["local_only"] != test.local {
				t.Fatalf("got %#v", got)
			}
			if got["fingerprint"] != "" || got["tls"] != false {
				t.Fatalf("TLS fields got %#v", got)
			}
		})
	}
}

func TestBuildMinerConnectionPortAndTLSInput(t *testing.T) {
	got, err := BuildMinerConnection(MinerConnectionInput{HostIP: "host", Bind: "0.0.0.0", Port: json.RawMessage(`"4444"`), TLS: "TRUE", Fingerprint: "hidden"})
	if err != nil {
		t.Fatal(err)
	}
	if got["url"] != "stratum+tcp://host:4444" || got["tls"] != false || got["fingerprint"] != "" {
		t.Fatalf("got %#v", got)
	}
	for _, raw := range []string{`""`, `4.5`, `true`, `4444 null`} {
		if _, err := BuildMinerConnection(MinerConnectionInput{HostIP: "host", Port: json.RawMessage(raw)}); err == nil {
			t.Fatalf("accepted port %q", raw)
		}
	}
}
