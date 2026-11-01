package firewall

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

func TestTorNFTValidation(t *testing.T) {
	config := TorConfig{Prefix: "172.28.0", Subnet: "172.28.0.0/24", Active: "172.28.0.26"}
	drop := []any{nftIPMatchTest("saddr", nftPrefixTest("172.28.0.0", 24)), map[string]any{"drop": nil}}
	active := []any{nftIPMatchTest("saddr", "172.28.0.26"), map[string]any{"accept": nil}}
	tests := []struct {
		name string
		doc  string
		want bool
		bad  bool
	}{
		{"healthy", torNFTDocument(active, drop), true, false},
		{"missing active", torNFTDocument(drop), false, false},
		{"duplicate active", torNFTDocument(active, active, drop), false, false},
		{"late active", torNFTDocument(drop, active), false, false},
		{"inactive exception", torNFTDocument([]any{nftIPMatchTest("saddr", "172.28.0.27"), map[string]any{"accept": nil}}, drop), false, false},
		{"conditional active", torNFTDocument([]any{nftIPMatchTest("saddr", "172.28.0.26"), nftIPMatchTest("daddr", "10.0.0.1"), map[string]any{"accept": nil}}, drop), false, false},
		{"unconditional accept", torNFTDocument([]any{map[string]any{"counter": map[string]any{}}, map[string]any{"accept": nil}}, active, drop), false, false},
		{"drop in unhooked chain", torNFTDocumentChain("input", active, drop), false, false},
		{"wrong chain", torNFTRaw(map[string]any{"nftables": []any{map[string]any{"chain": map[string]any{"name": "other", "hook": "forward"}}, map[string]any{"rule": map[string]any{"chain": "other", "expr": drop}}}}), false, false},
		{"malformed", `{`, false, true},
		{"concatenated", torNFTDocument(active, drop) + `{}`, false, true},
		{"duplicate key", `{"nftables":[],"nftables":[]}`, false, true},
		{"scalar entry", `{"nftables":[1]}`, false, true},
		{"scalar match", torNFTDocument([]any{map[string]any{"match": 1}, map[string]any{"accept": nil}}, active, drop), false, true},
		{"unsafe integer", torNFTDocument([]any{map[string]any{"match": map[string]any{"right": json.Number("9007199254740993")}}, map[string]any{"drop": nil}}), false, true},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			got, err := validateTorNFT(test.doc, config)
			if got != test.want || errors.Is(err, ErrUnsupportedInput) != test.bad {
				t.Fatalf("validateTorNFT() = %v, %v", got, err)
			}
		})
	}
}

func TestTorNFTSafeAccepts(t *testing.T) {
	config := TorConfig{Prefix: "172.28.0", Subnet: "172.28.0.0/24", Active: "172.28.0.26\n172.28.0.30"}
	subnet := nftPrefixTest("172.28.0.0", 24)
	rules := [][]any{nftReplyAccept()}
	rules = append(rules, []any{nftIPMatchTest("saddr", "172.28.0.25"), map[string]any{"accept": nil}})
	for _, destination := range []struct {
		addr string
		bits int
	}{{"10.0.0.0", 8}, {"172.16.0.0", 12}, {"192.168.0.0", 16}, {"100.64.0.0", 10}} {
		rules = append(rules, []any{nftIPMatchTest("saddr", subnet), nftIPMatchTest("daddr", nftPrefixTest(destination.addr, destination.bits)), map[string]any{"accept": nil}})
	}
	for _, ip := range []string{"172.28.0.26", "172.28.0.30"} {
		rules = append(rules, []any{nftIPMatchTest("saddr", ip), map[string]any{"accept": nil}})
	}
	for _, destination := range []struct {
		addr string
		bits int
	}{{"fc00::", 7}, {"fe80::", 10}} {
		rules = append(rules, []any{
			map[string]any{"match": map[string]any{"op": "==", "left": map[string]any{"meta": map[string]any{"key": "iifname", "extra": true}, "extra": true}, "right": "mining0", "extra": true}},
			map[string]any{"match": map[string]any{"op": "==", "left": map[string]any{"payload": map[string]any{"protocol": "ip6", "field": "daddr"}, "extra": true}, "right": nftPrefixTest(destination.addr, destination.bits), "extra": true}},
			map[string]any{"accept": nil},
		})
	}
	rules = append(rules, []any{nftIPMatchTest("saddr", subnet), map[string]any{"drop": nil}})
	if got, err := validateTorNFT(torNFTDocument(rules...), config); err != nil || !got {
		t.Fatalf("safe rules = %v, %v", got, err)
	}

	unsafe := []any{nftIPMatchTest("saddr", subnet), nftIPMatchTest("daddr", nftPrefixTest("8.8.8.0", 24)), map[string]any{"accept": nil}}
	if got, err := validateTorNFT(torNFTDocument(unsafe, rules[len(rules)-1]), TorConfig{Prefix: config.Prefix, Subnet: config.Subnet}); err != nil || got {
		t.Fatalf("unsafe accept = %v, %v", got, err)
	}
}

func TestTorNFTAvailabilityAndReads(t *testing.T) {
	t.Setenv("PITHEAD_ENGINE", "podman")
	dir := t.TempDir()
	writeTool(t, dir, "nft", "exit 0")
	t.Setenv("PATH", dir)
	if rc, err := TorEnforced(TorConfig{}); rc != 3 || err != nil {
		t.Fatalf("missing jq = %d, %v", rc, err)
	}
	writeTool(t, dir, "jq", "exit 0")
	if rc, err := TorEnforced(TorConfig{}); rc != 3 || err != nil {
		t.Fatalf("missing sudo = %d, %v", rc, err)
	}

	for _, test := range []struct {
		name, failure string
		want          int
	}{
		{"initial", "initial", 3},
		{"table", "table", 1},
		{"healthy", "", 0},
	} {
		t.Run(test.name, func(t *testing.T) {
			dir, log := torNFTTools(t, torNFTDocument([]any{nftIPMatchTest("saddr", nftPrefixTest("172.28.0.0", 24)), map[string]any{"drop": nil}}), test.failure)
			t.Setenv("PATH", dir)
			rc, err := TorEnforced(TorConfig{})
			if rc != test.want || err != nil {
				t.Fatalf("TorEnforced() = %d, %v", rc, err)
			}
			wantCalls := []string{"-n nft list tables", "-n nft -j list table inet " + torEgressNFTTable}
			if test.failure == "initial" {
				wantCalls = wantCalls[:1]
			}
			if got := readLines(t, log); !reflect.DeepEqual(got, wantCalls) {
				t.Fatalf("calls = %#v", got)
			}
		})
	}
}

func torNFTDocument(rules ...[]any) string {
	return torNFTDocumentChain("forward", rules...)
}

func torNFTDocumentChain(chain string, rules ...[]any) string {
	entries := []any{map[string]any{"chain": map[string]any{"name": chain, "hook": "forward"}}}
	for _, expr := range rules {
		entries = append(entries, map[string]any{"rule": map[string]any{"chain": chain, "expr": expr}})
	}
	return torNFTJSON(map[string]any{"nftables": entries})
}

func torNFTJSON(value any) string {
	body, err := json.Marshal(value)
	if err != nil {
		panic(err)
	}
	return string(body)
}

func torNFTRaw(value any) string {
	return torNFTJSON(value)
}

func nftIPMatchTest(field string, right any) map[string]any {
	return map[string]any{"match": map[string]any{"op": "==", "left": map[string]any{"payload": map[string]any{"protocol": "ip", "field": field}}, "right": right}}
}

func nftPrefixTest(addr string, bits int) map[string]any {
	return map[string]any{"prefix": map[string]any{"addr": addr, "len": bits}}
}

func torNFTTools(t *testing.T, document, failure string) (string, string) {
	t.Helper()
	dir := t.TempDir()
	log := filepath.Join(dir, "calls")
	writeTool(t, dir, "nft", "exit 0")
	writeTool(t, dir, "jq", "exit 0")
	body := "printf '%s\\n' \"$*\" >>'" + log + "'\ncase \"$*\" in\n"
	body += "'-n nft list tables') [ '" + failure + "' = initial ] && { printf partial; exit 1; }; true ;;\n"
	body += "'-n nft -j list table inet " + torEgressNFTTable + "') [ '" + failure + "' = table ] && { printf partial; exit 1; }; printf '%s\\n' '" + document + "' ;;\nesac"
	writeTool(t, dir, "sudo", body)
	return dir, log
}

func TestTorNFTUnsafeExecutable(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "nft"), []byte("exit 0\n"), 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", dir)
	t.Setenv("PITHEAD_ENGINE", "podman")
	if rc, err := TorEnforced(TorConfig{}); rc != 0 || !errors.Is(err, ErrUnsupportedInput) {
		t.Fatalf("unsafe nft = %d, %v", rc, err)
	}
}
