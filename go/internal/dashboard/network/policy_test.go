package network

import (
	"bytes"
	"encoding/json"
	"errors"
	"strings"
	"testing"
)

type failingWriter struct{}

func (failingWriter) Write([]byte) (int, error) {
	return 0, errors.New("write failed")
}

func basePolicy() policyInput {
	return policyInput{
		Firewall: true, MoneroRoute: routeLocal, TariRoute: routeLocal, TariEnabled: true,
		NotifyTor: true, StandbyRoute: routeInactive, StratumLabel: "stratum :3333",
	}
}

func findConnection(t *testing.T, posture Posture, component, destination string) Connection {
	t.Helper()
	for _, item := range posture.Components {
		if item.Name != component {
			continue
		}
		for _, connection := range item.Conns {
			if strings.Contains(connection.To, destination) {
				return connection
			}
		}
	}
	t.Fatalf("missing %s %s", component, destination)
	return Connection{}
}

func TestPostureClassifications(t *testing.T) {
	input := basePolicy()
	posture := buildPosture(input)
	if !posture.Summary.AllTor || posture.Summary.Label != "All egress via Tor" {
		t.Fatalf("base summary = %#v", posture.Summary)
	}

	input.P2PoolClearnet = true
	posture = buildPosture(input)
	connection := findConnection(t, posture, "p2pool", "sidechain")
	if !connection.ChosenClearnet || posture.Summary.AllTor || posture.Summary.Leaks != 0 {
		t.Fatalf("chosen posture = %#v %#v", connection, posture.Summary)
	}

	input = basePolicy()
	input.NotifySinksEnabled = true
	input.NotifyTor = false
	posture = buildPosture(input)
	if posture.Summary.Leaks != 1 || !findConnection(t, posture, "dashboard", "alert sinks").RouteIs(routeClearnet) {
		t.Fatalf("leak posture = %#v", posture)
	}

	input = basePolicy()
	input.MoneroRoute = routeClearnet
	posture = buildPosture(input)
	if posture.Summary.Leaks != 1 || posture.Summary.BlockedByFirewall != 1 {
		t.Fatalf("firewall posture = %#v", posture.Summary)
	}
	if !findConnection(t, posture, "p2pool", "monerod RPC").BlockedByFirewall {
		t.Fatal("missing blocked connection")
	}

	input = basePolicy()
	input.MoneroRoute = routeUnknown
	input.TariRoute = routeUnknown
	posture = buildPosture(input)
	if posture.Summary.Unverified != 4 || !strings.Contains(posture.Summary.Label, "4 egress path(s) unverified") {
		t.Fatalf("unknown posture = %#v", posture.Summary)
	}
}

func (connection Connection) RouteIs(route string) bool {
	return connection.Route == route
}

func TestPostureBooleanAndRouteSweep(t *testing.T) {
	routes := []string{routeLocal, routeLAN, routeClearnet, routeUnknown}
	for mask := 0; mask < 64; mask++ {
		for _, monero := range routes {
			for _, tari := range routes {
				input := basePolicy()
				input.Firewall = mask&1 != 0
				input.P2PoolClearnet = mask&2 != 0
				input.XVBEnabled = mask&4 != 0
				input.XVBTor = mask&8 != 0
				input.MoneroClearnetSync = mask&16 != 0
				input.TariClearnetSync = mask&32 != 0
				input.MoneroRoute = monero
				input.TariRoute = tari
				posture := buildPosture(input)
				if len(posture.Components) != 6 || posture.Summary.Level != "ok" && posture.Summary.Level != "warn" {
					t.Fatalf("mask=%d routes=%s,%s posture=%#v", mask, monero, tari, posture)
				}
				if posture.Summary.AllTor != (posture.Summary.Leaks == 0 && !hasChosen(posture) && posture.Summary.Unverified == 0) {
					t.Fatalf("inconsistent summary mask=%d routes=%s,%s", mask, monero, tari)
				}
			}
		}
	}
}

func hasChosen(posture Posture) bool {
	for _, component := range posture.Components {
		for _, connection := range component.Conns {
			if connection.ChosenClearnet {
				return true
			}
		}
	}
	return false
}

func TestTopologyEdgesClassificationAndOrder(t *testing.T) {
	input := basePolicy()
	input.P2PoolClearnet = true
	input.MoneroRoute = routeClearnet
	input.NotifySinksEnabled = true
	input.NotifyTor = false
	edges := buildEdges(input)
	if len(edges) < 20 || edges[0] != (Edge{From: "rigs", To: "xmrig-proxy", Route: routeIncoming, Label: "stratum :3333", Kind: "ingress"}) {
		t.Fatalf("edge prefix = %#v", edges)
	}
	states := map[string]Edge{}
	for _, link := range edges {
		states[link.From+"/"+link.Label] = link
	}
	if !states["p2pool/sidechain P2P"].ChosenClearnet || !states["p2pool/RPC / ZMQ"].BlockedByFirewall ||
		!states["dashboard/get_info RPC"].Leak || !states["dashboard/alert sinks"].Leak {
		t.Fatalf("edge classifications = %#v", states)
	}
}

func TestNodePlanSelectionAndRelocation(t *testing.T) {
	nodes := []Node{
		{ID: "fixed", Zone: "host"},
		{ID: "monerod", Zone: "host"},
		{ID: "local-miner", Zone: "host"},
		{ID: "tari", Zone: "host"},
		{ID: "monerod", Zone: "second"},
	}
	plan := buildNodePlan(nodes, routeLAN, routeLocal, false, false)
	wantIndices := []int{0, 1, 4}
	if !equalInts(plan.Indices, wantIndices) || len(plan.Relocatable) != 2 {
		t.Fatalf("plan = %#v", plan)
	}
	for index, patch := range plan.Relocatable {
		if patch.Index != []int{1, 4}[index] || patch.Zone != "remote" || !patch.Remote || patch.Route != routeLAN {
			t.Fatalf("patch = %#v", patch)
		}
	}
	nodes[1].Zone = "changed"
	if plan.Relocatable[0].Zone != "remote" {
		t.Fatalf("plan changed with input: %#v", plan)
	}
}

func equalInts(left, right []int) bool {
	if len(left) != len(right) {
		return false
	}
	for index := range left {
		if left[index] != right[index] {
			return false
		}
	}
	return true
}

func TestProtocolRejectsMalformedRequests(t *testing.T) {
	valid := validPolicyJSON(t, "posture")
	cases := []string{
		`{"operation":"missing"}`,
		`{"operation":"posture"}`,
		strings.Replace(valid, `"monero_route":"local"`, `"monero_route":"bad"`, 1),
		strings.TrimSuffix(valid, "}") + `,"extra":true}`,
		valid + ` {}`,
		`{"operation":"topology-nodes","nodes":null,"monero_route":"local","tari_route":"local","tari_enabled":true,"local_miner_enabled":true}`,
	}
	for _, input := range cases {
		if _, err := build([]byte(input)); err == nil {
			t.Fatalf("accepted %s", input)
		}
	}

	var output bytes.Buffer
	if err := Run(strings.NewReader(cases[0]), &output); err != nil {
		t.Fatal(err)
	}
	var response wireResponse
	if err := json.Unmarshal(output.Bytes(), &response); err != nil || response.OK || response.Error == nil || response.Error.Kind != "ValueError" {
		t.Fatalf("response = %s err=%v", output.String(), err)
	}
}

func TestProtocolBuildsEveryOperation(t *testing.T) {
	posture, err := build([]byte(validPolicyJSON(t, "posture")))
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := posture.(Posture); !ok {
		t.Fatalf("posture type = %T", posture)
	}

	edgeJSON := strings.TrimSuffix(validPolicyJSON(t, "topology-edges"), "}") + `,"local_miner_enabled":true,"stratum_label":"stratum :1234"}`
	edges, err := build([]byte(edgeJSON))
	if err != nil {
		t.Fatal(err)
	}
	if links, ok := edges.([]Edge); !ok || len(links) == 0 || links[0].Label != "stratum :1234" {
		t.Fatalf("edges = %#v", edges)
	}

	nodes, err := build([]byte(`{"operation":"topology-nodes","nodes":[{"id":"monerod","zone":"host"},{"id":"fixed","zone":"host"}],"monero_route":"lan","tari_route":"local","tari_enabled":true,"local_miner_enabled":true}`))
	if err != nil {
		t.Fatal(err)
	}
	plan, ok := nodes.(NodePlan)
	if !ok || len(plan.Indices) != 2 || len(plan.Relocatable) != 1 || plan.Relocatable[0].Zone != "remote" {
		t.Fatalf("nodes = %#v", nodes)
	}
}

func TestRunPropagatesWriteAndSizeErrors(t *testing.T) {
	valid := validPolicyJSON(t, "posture")
	if err := Run(strings.NewReader(valid), failingWriter{}); err == nil || err.Error() != "write failed" {
		t.Fatalf("write error = %v", err)
	}
	var output bytes.Buffer
	if err := Run(strings.NewReader(strings.Repeat("x", maxRequestBytes+1)), &output); err != nil {
		t.Fatal(err)
	}
	var response wireResponse
	if err := json.Unmarshal(output.Bytes(), &response); err != nil || response.OK || response.Error == nil || response.Error.Message != "network request exceeds size limit" {
		t.Fatalf("size response = %s err=%v", output.String(), err)
	}
}

func validPolicyJSON(t *testing.T, operation string) string {
	t.Helper()
	request := map[string]any{
		"operation": operation, "firewall": true, "p2pool_clearnet": false, "xvb_enabled": false, "xvb_tor": true,
		"monero_clearnet_sync": false, "tari_clearnet_sync": false, "monero_route": routeLocal, "tari_route": routeLocal,
		"tari_enabled": true, "healthchecks_enabled": false, "telegram_enabled": false, "price_feed_enabled": false,
		"notify_sinks_enabled": false, "notify_tor": true, "notify_sinks_private": false, "standby_route": routeInactive,
		"tor_auto_heal": false, "tari_explorer": false,
	}
	encoded, err := json.Marshal(request)
	if err != nil {
		t.Fatal(err)
	}
	return string(encoded)
}
