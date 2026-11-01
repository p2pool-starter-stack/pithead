//go:build parity

package doctor

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func newNFTEgressFixture(t *testing.T) egressFixture {
	t.Helper()
	fixture := newEgressFixture(t)
	t.Setenv("PITHEAD_ENGINE", "podman")
	writeHostTool(t, fixture.lan.Bin, "nft", egressToolLog+"case \"$*\" in\n'list tables') key=all ;; '-j list table inet pithead_egress') key=table ;; *) exit 99 ;;\nesac\nif [ -f \"$0.$key.output\" ]; then /bin/cat \"$0.$key.output\"; fi\ncode=1\nif [ -f \"$0.$key.code\" ]; then IFS= read -r code <\"$0.$key.code\"; fi\nexit \"$code\"\n")
	egressResponse(t, fixture, "nft", "all", "", 0)
	egressResponse(t, fixture, "nft", "table", nftEgressDocument(t, nftSubnetDrop()), 0)
	return fixture
}

func nftEgressDocument(t *testing.T, expressions ...[]any) string {
	t.Helper()
	entries := []any{
		map[string]any{"metainfo": map[string]any{"version": "fixture", "json_schema_version": 1}},
		map[string]any{"table": map[string]any{"family": "inet", "name": "pithead_egress"}},
		map[string]any{"chain": map[string]any{"family": "inet", "table": "pithead_egress", "name": "forward", "hook": "forward", "type": "filter", "prio": -5, "policy": "accept"}},
	}
	for _, expression := range expressions {
		entries = append(entries, map[string]any{"rule": map[string]any{"family": "inet", "table": "pithead_egress", "chain": "forward", "expr": expression}})
	}
	encoded, err := json.Marshal(map[string]any{"nftables": entries})
	if err != nil {
		t.Fatal(err)
	}
	return string(encoded)
}

func nftPrefix(address string, length int) map[string]any {
	return map[string]any{"prefix": map[string]any{"addr": address, "len": length}}
}

func nftIPMatch(field string, right any) map[string]any {
	return map[string]any{"match": map[string]any{"op": "==", "left": map[string]any{"payload": map[string]any{"protocol": "ip", "field": field}}, "right": right}}
}

func nftSubnetDrop() []any {
	return []any{nftIPMatch("saddr", nftPrefix("172.28.0.0", 24)), map[string]any{"drop": nil}}
}

func nftIPAccept(ip string) []any {
	return []any{nftIPMatch("saddr", ip), map[string]any{"accept": nil}}
}

func nftReplyAccept() []any {
	return []any{
		map[string]any{"match": map[string]any{"op": "==", "left": map[string]any{"ct": map[string]any{"key": "direction"}}, "right": "reply"}},
		map[string]any{"match": map[string]any{"op": "in", "left": map[string]any{"ct": map[string]any{"key": "state"}}, "right": []string{"established", "related"}}},
		map[string]any{"accept": nil},
	}
}

func nftLocalAccept(destination string, length int) []any {
	return []any{nftIPMatch("saddr", nftPrefix("172.28.0.0", 24)), nftIPMatch("daddr", nftPrefix(destination, length)), map[string]any{"accept": nil}}
}

func nftIPv6LocalAccept(destination string, length int) []any {
	return []any{
		map[string]any{"match": map[string]any{"op": "==", "left": map[string]any{"meta": map[string]any{"key": "iifname"}}, "right": "fixture-bridge"}},
		map[string]any{"match": map[string]any{"op": "==", "left": map[string]any{"payload": map[string]any{"protocol": "ip6", "field": "daddr"}}, "right": nftPrefix(destination, length)}},
		map[string]any{"accept": nil},
	}
}

func removeNFTTool(t *testing.T, fixture egressFixture, name string) {
	t.Helper()
	if err := os.Remove(filepath.Join(fixture.lan.Bin, name)); err != nil {
		t.Fatal(err)
	}
}
