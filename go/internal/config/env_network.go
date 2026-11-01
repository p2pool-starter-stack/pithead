package config

import (
	"encoding/json"
	"errors"
	"strings"
)

var ErrUnsupportedNetwork = errors.New("unsupported network environment plan")

type NetworkInput struct {
	ModeMonero          string
	ModeTari            string
	NetworkPrefix       string
	MoneroRemoteHost    string
	MoneroRemoteRPCPort string
	MoneroRemoteZMQPort string
	TariRemoteHost      string
	TariRemoteGRPCPort  string
	PayoutConfirm       string
	TariPayoutConfirm   string
}

type NetworkPlan struct {
	MonoHost       string
	RPCPort        string
	ZMQPort        string
	MonoRPCURL     string
	Profiles       string
	TariGRPCAddr   string
	TorProfiles    string
	TariGRPCBind   string
	Prune          string
	MoneroClearnet string
	TariClearnet   string
	PrepThreads    string
	OutPeers       string
	RPCBind        string
	ZMQBind        string
	PoolType       string
	P2PoolFlags    string
	P2PoolPort     string
	P2PoolSocks    string
}

func (plan NetworkPlan) Values() []string {
	return []string{
		plan.MonoHost,
		plan.RPCPort,
		plan.ZMQPort,
		plan.MonoRPCURL,
		plan.Profiles,
		plan.TariGRPCAddr,
		plan.TorProfiles,
		plan.TariGRPCBind,
		plan.Prune,
		plan.MoneroClearnet,
		plan.TariClearnet,
		plan.PrepThreads,
		plan.OutPeers,
		plan.RPCBind,
		plan.ZMQBind,
		plan.PoolType,
		plan.P2PoolFlags,
		plan.P2PoolPort,
		plan.P2PoolSocks,
	}
}

func DeriveNetwork(raw []byte, input NetworkInput) (NetworkPlan, error) {
	document, err := ParseDocument(raw)
	if err != nil || document == nil || duplicateError(document.root, "") != "" {
		return NetworkPlan{}, ErrUnsupportedNetwork
	}

	values, err := networkConfigValues(document.root)
	if err != nil {
		return NetworkPlan{}, err
	}

	plan := NetworkPlan{
		TariGRPCAddr: input.NetworkPrefix + ".27:18142",
		TariGRPCBind: "127.0.0.1",
		Prune:        "0",
		OutPeers:     values.outPeers,
		RPCBind:      "127.0.0.1",
		ZMQBind:      "127.0.0.1",
		PoolType:     values.poolType,
		P2PoolPort:   "37889",
	}

	if input.ModeMonero == "local" {
		plan.MonoHost = input.NetworkPrefix + ".26"
		plan.RPCPort = "18081"
		plan.ZMQPort = "18083"
		plan.MonoRPCURL = "http://127.0.0.1:18081"
		plan.Profiles = "local_node"
	} else {
		plan.MonoHost = input.MoneroRemoteHost
		plan.RPCPort = input.MoneroRemoteRPCPort
		plan.ZMQPort = input.MoneroRemoteZMQPort
		host := plan.MonoHost
		if strings.Contains(host, ":") {
			host = "[" + host + "]"
		}
		plan.MonoRPCURL = "http://" + host + ":" + plan.RPCPort
	}

	if input.ModeTari == "local" {
		plan.Profiles = appendProfile(plan.Profiles, "local_tari")
	} else if input.ModeTari == "remote" {
		plan.TariGRPCAddr = input.TariRemoteHost + ":" + input.TariRemoteGRPCPort
	}
	plan.TorProfiles = plan.Profiles
	if values.tariGRPCLAN == "true" {
		plan.TariGRPCBind = "0.0.0.0"
	}
	if input.PayoutConfirm == "true" {
		plan.Profiles = appendProfile(plan.Profiles, "payout_confirm")
	}
	if input.TariPayoutConfirm == "true" {
		plan.Profiles = appendProfile(plan.Profiles, "tari_payout_confirm")
	}

	if values.prune == "true" {
		plan.Prune = "1"
	}
	plan.MoneroClearnet = normalizedBool(values.moneroClearnet)
	plan.TariClearnet = normalizedBool(values.tariClearnet)
	if decimalDigits(values.prepThreads) {
		plan.PrepThreads = values.prepThreads
	}
	if values.rpcLAN == "true" {
		plan.RPCBind = "0.0.0.0"
	}
	if values.zmqLAN == "true" {
		plan.ZMQBind = "0.0.0.0"
	}

	switch plan.PoolType {
	case "mini":
		plan.P2PoolFlags = "--mini"
		plan.P2PoolPort = "37888"
	case "nano":
		plan.P2PoolFlags = "--nano"
		plan.P2PoolPort = "37890"
	}
	if normalizedBool(values.p2poolClearnet) != "true" {
		prefix := input.NetworkPrefix
		if prefix == "" {
			prefix = "172.28.0"
		}
		plan.P2PoolSocks = "--socks5 " + prefix + ".25:9050 --socks5-proxy-type tor --no-dns"
		if plan.P2PoolFlags != "" {
			plan.P2PoolFlags += " "
		}
		plan.P2PoolFlags += plan.P2PoolSocks
	}
	return plan, nil
}

type networkValues struct {
	tariGRPCLAN    string
	prune          string
	moneroClearnet string
	tariClearnet   string
	prepThreads    string
	outPeers       string
	rpcLAN         string
	zmqLAN         string
	poolType       string
	p2poolClearnet string
}

type networkLookup struct {
	path        string
	fallback    node
	nullOnly    bool
	destination *string
}

func networkConfigValues(root node) (networkValues, error) {
	values := networkValues{}
	lookups := []networkLookup{
		{"tari.grpc_lan_access", node{value: false}, false, &values.tariGRPCLAN},
		{"monero.prune", node{value: true}, true, &values.prune},
		{"monero.clearnet_initial_sync", node{value: false}, true, &values.moneroClearnet},
		{"tari.clearnet_initial_sync", node{value: false}, true, &values.tariClearnet},
		{"monero.prep_blocks_threads", node{value: "auto"}, false, &values.prepThreads},
		{"monero.out_peers", node{value: json.Number("48")}, false, &values.outPeers},
		{"monero.rpc_lan_access", node{value: false}, false, &values.rpcLAN},
		{"monero.zmq_lan_access", node{value: false}, false, &values.zmqLAN},
		{"p2pool.pool", node{value: "mini"}, false, &values.poolType},
		{"p2pool.clearnet", node{value: false}, false, &values.p2poolClearnet},
	}
	for _, lookup := range lookups {
		value, err := networkScalar(root, lookup.path, lookup.fallback, lookup.nullOnly)
		if err != nil {
			return networkValues{}, err
		}
		*lookup.destination = value
	}
	return values, nil
}

func networkScalar(root node, path string, fallback node, nullOnly bool) (string, error) {
	value, err := getStringPath(root, path)
	if err != nil || value.object != nil || value.array != nil {
		return "", ErrUnsupportedNetwork
	}
	if isNull(value) || !nullOnly && value.value == false {
		value = fallback
	}
	if text, ok := value.value.(string); ok {
		for _, current := range text {
			if current <= 0x1f || current >= 0x7f && current <= 0x9f {
				return "", ErrUnsupportedNetwork
			}
		}
		return text, nil
	}
	rendered, err := rawJQ(value)
	if err != nil {
		return "", ErrUnsupportedNetwork
	}
	return strings.TrimSuffix(string(rendered), "\n"), nil
}

func appendProfile(profiles, profile string) string {
	if profiles == "" {
		return profile
	}
	return profiles + "," + profile
}

func normalizedBool(value string) string {
	var lowered strings.Builder
	for _, current := range value {
		if current >= 'A' && current <= 'Z' {
			current += 'a' - 'A'
		}
		lowered.WriteRune(current)
	}
	switch lowered.String() {
	case "true", "1", "yes", "on":
		return "true"
	default:
		return "false"
	}
}

func decimalDigits(value string) bool {
	if value == "" {
		return false
	}
	for _, current := range value {
		if current < '0' || current > '9' {
			return false
		}
	}
	return true
}
