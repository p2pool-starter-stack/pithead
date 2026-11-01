package config

import (
	"errors"
	"reflect"
	"testing"
)

func TestDeriveNetworkDefaultsAndProfileSnapshot(t *testing.T) {
	input := NetworkInput{
		ModeMonero:        "local",
		ModeTari:          "local",
		NetworkPrefix:     "172.28.0",
		PayoutConfirm:     "true",
		TariPayoutConfirm: "true",
	}
	got, err := DeriveNetwork([]byte(`{}`), input)
	want := NetworkPlan{
		MonoHost:       "172.28.0.26",
		RPCPort:        "18081",
		ZMQPort:        "18083",
		MonoRPCURL:     "http://127.0.0.1:18081",
		Profiles:       "local_node,local_tari,payout_confirm,tari_payout_confirm",
		TariGRPCAddr:   "172.28.0.27:18142",
		TorProfiles:    "local_node,local_tari",
		TariGRPCBind:   "127.0.0.1",
		Prune:          "1",
		MoneroClearnet: "false",
		TariClearnet:   "false",
		OutPeers:       "48",
		RPCBind:        "127.0.0.1",
		ZMQBind:        "127.0.0.1",
		PoolType:       "mini",
		P2PoolFlags:    "--mini --socks5 172.28.0.25:9050 --socks5-proxy-type tor --no-dns",
		P2PoolPort:     "37888",
		P2PoolSocks:    "--socks5 172.28.0.25:9050 --socks5-proxy-type tor --no-dns",
	}
	if err != nil || !reflect.DeepEqual(got, want) {
		t.Fatalf("DeriveNetwork() = %#v, %v; want %#v, nil", got, err, want)
	}
	if !reflect.DeepEqual(got.Values(), []string{
		got.MonoHost, got.RPCPort, got.ZMQPort, got.MonoRPCURL, got.Profiles,
		got.TariGRPCAddr, got.TorProfiles, got.TariGRPCBind, got.Prune,
		got.MoneroClearnet, got.TariClearnet, got.PrepThreads, got.OutPeers,
		got.RPCBind, got.ZMQBind, got.PoolType, got.P2PoolFlags, got.P2PoolPort,
		got.P2PoolSocks,
	}) {
		t.Fatalf("Values() returned the wrong order: %#v", got.Values())
	}
}

func TestDeriveNetworkRemoteAddressesAndConfiguredValues(t *testing.T) {
	raw := []byte(`{
		"tari":{"grpc_lan_access":true,"clearnet_initial_sync":"ON"},
		"monero":{"prune":false,"clearnet_initial_sync":"YeS","prep_blocks_threads":"07","out_peers":64,"rpc_lan_access":true,"zmq_lan_access":true},
		"p2pool":{"pool":"nano","clearnet":1}
	}`)
	input := NetworkInput{
		ModeMonero:          "remote",
		ModeTari:            "remote",
		NetworkPrefix:       "10.20.30",
		MoneroRemoteHost:    "2001:db8::20",
		MoneroRemoteRPCPort: "28081",
		MoneroRemoteZMQPort: "28083",
		TariRemoteHost:      "tari.example",
		TariRemoteGRPCPort:  "19142",
		PayoutConfirm:       "TRUE",
	}
	got, err := DeriveNetwork(raw, input)
	if err != nil {
		t.Fatal(err)
	}
	checks := map[string][2]string{
		"mono host":       {got.MonoHost, "2001:db8::20"},
		"mono URL":        {got.MonoRPCURL, "http://[2001:db8::20]:28081"},
		"profiles":        {got.Profiles, ""},
		"Tor profiles":    {got.TorProfiles, ""},
		"Tari address":    {got.TariGRPCAddr, "tari.example:19142"},
		"Tari bind":       {got.TariGRPCBind, "0.0.0.0"},
		"prune":           {got.Prune, "0"},
		"Monero clearnet": {got.MoneroClearnet, "true"},
		"Tari clearnet":   {got.TariClearnet, "true"},
		"prep threads":    {got.PrepThreads, "07"},
		"out peers":       {got.OutPeers, "64"},
		"RPC bind":        {got.RPCBind, "0.0.0.0"},
		"ZMQ bind":        {got.ZMQBind, "0.0.0.0"},
		"pool":            {got.PoolType, "nano"},
		"p2pool flags":    {got.P2PoolFlags, "--nano"},
		"p2pool port":     {got.P2PoolPort, "37890"},
		"p2pool socks":    {got.P2PoolSocks, ""},
	}
	for name, check := range checks {
		if check[0] != check[1] {
			t.Errorf("%s = %q; want %q", name, check[0], check[1])
		}
	}
}

func TestDeriveNetworkJQAlternativeAndComparisonSemantics(t *testing.T) {
	raw := []byte(`{
		"tari":{"grpc_lan_access":"true","clearnet_initial_sync":false},
		"monero":{"prune":"true","clearnet_initial_sync":true,"prep_blocks_threads":false,"out_peers":false,"rpc_lan_access":"TRUE","zmq_lan_access":1},
		"p2pool":{"pool":false,"clearnet":"yes"}
	}`)
	got, err := DeriveNetwork(raw, NetworkInput{ModeMonero: "local", ModeTari: "off"})
	if err != nil {
		t.Fatal(err)
	}
	if got.TariGRPCBind != "0.0.0.0" || got.Prune != "1" || got.MoneroClearnet != "true" || got.TariClearnet != "false" {
		t.Fatalf("boolean semantics differ: %#v", got)
	}
	if got.PrepThreads != "" || got.OutPeers != "48" || got.RPCBind != "127.0.0.1" || got.ZMQBind != "127.0.0.1" {
		t.Fatalf("alternative/comparison semantics differ: %#v", got)
	}
	if got.PoolType != "mini" || got.P2PoolFlags != "--mini" || got.P2PoolSocks != "" {
		t.Fatalf("p2pool semantics differ: %#v", got)
	}
}

func TestDeriveNetworkEmptyPrefixUsesOnlySocksDefault(t *testing.T) {
	got, err := DeriveNetwork([]byte(`{"p2pool":{"pool":"main"}}`), NetworkInput{ModeMonero: "local", ModeTari: "off"})
	if err != nil {
		t.Fatal(err)
	}
	if got.MonoHost != ".26" || got.TariGRPCAddr != ".27:18142" {
		t.Fatalf("local addresses = %q, %q", got.MonoHost, got.TariGRPCAddr)
	}
	if got.P2PoolSocks != "--socks5 172.28.0.25:9050 --socks5-proxy-type tor --no-dns" {
		t.Fatalf("socks flags = %q", got.P2PoolSocks)
	}
	if got.P2PoolFlags != got.P2PoolSocks || got.P2PoolPort != "37889" {
		t.Fatalf("main pool flags and port = %q, %q", got.P2PoolFlags, got.P2PoolPort)
	}
}

func TestDeriveNetworkRejectsInputsThatCannotMatchJQ(t *testing.T) {
	tests := map[string]string{
		"invalid JSON":   `{`,
		"duplicate":      `{"monero":{},"monero":{}}`,
		"scalar parent":  `{"monero":4}`,
		"compound leaf":  `{"p2pool":{"pool":[]}}`,
		"control string": `{"p2pool":{"pool":"mini\nother"}}`,
		"decimal":        `{"monero":{"out_peers":48.0}}`,
		"unsafe integer": `{"monero":{"out_peers":9007199254740992}}`,
		"negative zero":  `{"monero":{"out_peers":-0}}`,
	}
	for name, raw := range tests {
		t.Run(name, func(t *testing.T) {
			got, err := DeriveNetwork([]byte(raw), NetworkInput{})
			if got != (NetworkPlan{}) || !errors.Is(err, ErrUnsupportedNetwork) {
				t.Fatalf("DeriveNetwork() = %#v, %v; want zero, unsupported", got, err)
			}
		})
	}
}
