package firewall

import (
	"reflect"
	"strings"
)

func torNFTSafeAccept(expr []any, config TorConfig, subnet map[string]any) bool {
	if reflect.DeepEqual(expr, nftReplyAccept()) || reflect.DeepEqual(expr, []any{nftIPMatch("saddr", config.Prefix+".25"), map[string]any{"accept": nil}}) {
		return true
	}
	for _, active := range splitActiveNFT(config.Active) {
		if reflect.DeepEqual(expr, []any{nftIPMatch("saddr", active), map[string]any{"accept": nil}}) {
			return true
		}
	}
	for _, destination := range []string{"10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "100.64.0.0/10"} {
		prefix, err := nftPrefix(destination)
		if err != nil {
			return false
		}
		expected := []any{nftIPMatch("saddr", subnet), nftIPMatch("daddr", prefix), map[string]any{"accept": nil}}
		if reflect.DeepEqual(expr, expected) {
			return true
		}
	}
	for _, destination := range []string{"fc00::/7", "fe80::/10"} {
		prefix, err := nftPrefix(destination)
		if err != nil {
			return false
		}
		expected := []any{
			map[string]any{"match": map[string]any{"op": "==", "left": map[string]any{"meta": map[string]any{"key": "iifname"}}}},
			map[string]any{"match": map[string]any{"op": "==", "left": map[string]any{"payload": map[string]any{"protocol": "ip6", "field": "daddr"}}, "right": prefix}},
			map[string]any{"accept": nil},
		}
		if torNFTIPv6Accept(expr, expected) {
			return true
		}
	}
	return false
}

func nftReplyAccept() []any {
	return []any{
		map[string]any{"match": map[string]any{"op": "==", "left": map[string]any{"ct": map[string]any{"key": "direction"}}, "right": "reply"}},
		map[string]any{"match": map[string]any{"op": "in", "left": map[string]any{"ct": map[string]any{"key": "state"}}, "right": []any{"established", "related"}}},
		map[string]any{"accept": nil},
	}
}

func torNFTIPv6Accept(expr, expected []any) bool {
	if len(expr) != len(expected) || !reflect.DeepEqual(expr[2], expected[2]) {
		return false
	}
	first, ok := expr[0].(map[string]any)["match"].(map[string]any)
	if !ok {
		return false
	}
	firstLeft, ok := first["left"].(map[string]any)
	if !ok {
		return false
	}
	meta, ok := firstLeft["meta"].(map[string]any)
	if !ok || first["op"] != "==" || meta["key"] != "iifname" {
		return false
	}
	second, ok := expr[1].(map[string]any)["match"].(map[string]any)
	if !ok || second["op"] != "==" {
		return false
	}
	secondLeft, ok := second["left"].(map[string]any)
	if !ok || !reflect.DeepEqual(secondLeft["payload"], map[string]any{"protocol": "ip6", "field": "daddr"}) {
		return false
	}
	expectedSecond := expected[1].(map[string]any)["match"].(map[string]any)
	return reflect.DeepEqual(second["right"], expectedSecond["right"])
}

func nftSourceMatch(expr []any, ip string) bool {
	payload := map[string]any{"protocol": "ip", "field": "saddr"}
	for _, value := range expr {
		match, ok := value.(map[string]any)["match"].(map[string]any)
		if !ok || match["right"] != ip {
			continue
		}
		left, ok := match["left"].(map[string]any)
		if ok && reflect.DeepEqual(left["payload"], payload) {
			return true
		}
	}
	return false
}

func activeNFTIP(active, ip string) int {
	for _, value := range splitActiveNFT(active) {
		if value == ip {
			return 1
		}
	}
	return 0
}

func splitActiveNFT(active string) []string {
	values := make([]string, 0)
	for _, value := range strings.Split(active, "\n") {
		if value != "" {
			values = append(values, value)
		}
	}
	return values
}
