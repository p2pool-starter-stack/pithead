package firewall

import (
	"encoding/json"
	"errors"
	"io"
	"reflect"
	"strconv"
	"strings"
)

const torEgressNFTTable = "pithead_egress"

func torNFTEnforced(config TorConfig) (int, error) {
	nft, err := tool("nft")
	if err != nil {
		return 0, err
	}
	if nft == "" {
		return 2, nil
	}
	if err := executable(nft); err != nil {
		return 0, err
	}
	jq, err := tool("jq")
	if err != nil {
		return 0, err
	}
	if jq == "" {
		return 3, nil
	}
	if err := executable(jq); err != nil {
		return 0, err
	}
	sudo, err := tool("sudo")
	if err != nil {
		return 0, err
	}
	if sudo == "" {
		return 3, nil
	}
	if _, ok, err := command(sudo, "-n", "nft", "list", "tables"); err != nil {
		return 0, err
	} else if !ok {
		return 3, nil
	}
	out, ok, err := command(sudo, "-n", "nft", "-j", "list", "table", "inet", torEgressNFTTable)
	if err != nil {
		return 0, err
	}
	if !ok {
		return 1, nil
	}
	config, err = config.values()
	if err != nil {
		return 0, err
	}
	enforced, err := validateTorNFT(out, config)
	if err != nil {
		return 0, err
	}
	if !enforced {
		return 1, nil
	}
	return 0, nil
}

func validateTorNFT(value string, config TorConfig) (bool, error) {
	entries, err := decodeTorNFT(value)
	if err != nil {
		return false, err
	}
	rules, hooked, err := torNFTRules(entries)
	if err != nil {
		return false, err
	}
	firstDrop := -1
	for index, rule := range rules {
		if !hooked[rule.chain] {
			continue
		}
		if nftVerdict(rule.expr, "drop") {
			if firstDrop < 0 {
				firstDrop = index
			}
			continue
		}
		if firstDrop < 0 && nftUnconditionalAccept(rule.expr) {
			return false, nil
		}
	}
	if firstDrop < 0 {
		return false, nil
	}
	return torNFTSyncMatches(entries, rules, config)
}

type torNFTRule struct {
	chain string
	expr  []any
}

func decodeTorNFT(value string) ([]any, error) {
	if err := rejectDuplicateNFTKeys(value); err != nil {
		return nil, err
	}
	decoder := json.NewDecoder(strings.NewReader(value))
	decoder.UseNumber()
	var document map[string]any
	if err := decoder.Decode(&document); err != nil {
		return nil, ErrUnsupportedInput
	}
	if err := decoder.Decode(&struct{}{}); !errors.Is(err, io.EOF) {
		return nil, ErrUnsupportedInput
	}
	normalized, err := normalizeJSONNumbers(document)
	if err != nil {
		return nil, err
	}
	document, ok := normalized.(map[string]any)
	if !ok || len(document) != 1 {
		return nil, ErrUnsupportedInput
	}
	entries, ok := document["nftables"].([]any)
	if !ok {
		return nil, ErrUnsupportedInput
	}
	return entries, nil
}

func rejectDuplicateNFTKeys(value string) error {
	decoder := json.NewDecoder(strings.NewReader(value))
	decoder.UseNumber()
	if err := uniqueNFTValue(decoder); err != nil {
		return ErrUnsupportedInput
	}
	if _, err := decoder.Token(); !errors.Is(err, io.EOF) {
		return ErrUnsupportedInput
	}
	return nil
}

func uniqueNFTValue(decoder *json.Decoder) error {
	token, err := decoder.Token()
	if err != nil {
		return err
	}
	delimiter, ok := token.(json.Delim)
	if !ok {
		return nil
	}
	switch delimiter {
	case '{':
		seen := make(map[string]bool)
		for decoder.More() {
			key, err := decoder.Token()
			if err != nil {
				return err
			}
			name, ok := key.(string)
			if !ok || seen[name] {
				return ErrUnsupportedInput
			}
			seen[name] = true
			if err := uniqueNFTValue(decoder); err != nil {
				return err
			}
		}
		end, err := decoder.Token()
		if err != nil || end != json.Delim('}') {
			return ErrUnsupportedInput
		}
	case '[':
		for decoder.More() {
			if err := uniqueNFTValue(decoder); err != nil {
				return err
			}
		}
		end, err := decoder.Token()
		if err != nil || end != json.Delim(']') {
			return ErrUnsupportedInput
		}
	default:
		return ErrUnsupportedInput
	}
	return nil
}

func torNFTRules(entries []any) ([]torNFTRule, map[string]bool, error) {
	rules := make([]torNFTRule, 0)
	hooked := make(map[string]bool)
	for _, value := range entries {
		entry, ok := value.(map[string]any)
		if !ok {
			return nil, nil, ErrUnsupportedInput
		}
		chainValue, hasChain := entry["chain"]
		ruleValue, hasRule := entry["rule"]
		if hasChain && hasRule {
			return nil, nil, ErrUnsupportedInput
		}
		if hasChain {
			chain, ok := chainValue.(map[string]any)
			if !ok {
				return nil, nil, ErrUnsupportedInput
			}
			name, ok := chain["name"].(string)
			if !ok {
				return nil, nil, ErrUnsupportedInput
			}
			if hook, exists := chain["hook"]; exists {
				hook, ok := hook.(string)
				if !ok {
					return nil, nil, ErrUnsupportedInput
				}
				if hook == "forward" {
					hooked[name] = true
				}
			}
		}
		if !hasRule {
			continue
		}
		rule, ok := ruleValue.(map[string]any)
		if !ok {
			return nil, nil, ErrUnsupportedInput
		}
		chain, ok := rule["chain"].(string)
		if !ok {
			return nil, nil, ErrUnsupportedInput
		}
		expr, ok := rule["expr"].([]any)
		if !ok {
			return nil, nil, ErrUnsupportedInput
		}
		for _, part := range expr {
			if _, ok := part.(map[string]any); !ok {
				return nil, nil, ErrUnsupportedInput
			}
		}
		rules = append(rules, torNFTRule{chain: chain, expr: expr})
	}
	return rules, hooked, nil
}

func torNFTSyncMatches(entries []any, rules []torNFTRule, config TorConfig) (bool, error) {
	for _, value := range entries {
		entry := value.(map[string]any)
		if chain, ok := entry["chain"]; ok {
			if chain.(map[string]any)["name"] != "forward" {
				return false, nil
			}
			continue
		}
		if _, ok := entry["rule"]; !ok {
			continue
		}
	}
	subnet, err := nftPrefix(config.Subnet)
	if err != nil {
		return false, err
	}
	drop := []any{nftIPMatch("saddr", subnet), map[string]any{"drop": nil}}
	dropIndex, exactDrop := -1, false
	for index, rule := range rules {
		if rule.chain != "forward" || len(rule.expr) == 0 {
			return false, nil
		}
		last := rule.expr[len(rule.expr)-1].(map[string]any)
		if !hasAnyKey(last, "accept", "drop", "reject") {
			return false, nil
		}
		for _, value := range rule.expr[:len(rule.expr)-1] {
			match, ok := value.(map[string]any)["match"]
			if !ok {
				return false, nil
			}
			if _, ok := match.(map[string]any); !ok {
				return false, ErrUnsupportedInput
			}
		}
		if dropIndex < 0 && nftVerdict(rule.expr, "drop") {
			dropIndex = index
		}
		if reflect.DeepEqual(rule.expr, drop) {
			exactDrop = true
		}
		if nftVerdict(rule.expr, "accept") && !torNFTSafeAccept(rule.expr, config, subnet) {
			return false, nil
		}
	}
	if !exactDrop {
		return false, nil
	}
	for _, suffix := range []string{"26", "27", "28", "29"} {
		ip := config.Prefix + "." + suffix
		expected := activeNFTIP(config.Active, ip)
		actual := 0
		for index, rule := range rules {
			if !nftVerdict(rule.expr, "accept") || !nftSourceMatch(rule.expr, ip) {
				continue
			}
			if !reflect.DeepEqual(rule.expr, []any{nftIPMatch("saddr", ip), map[string]any{"accept": nil}}) || index >= dropIndex {
				return false, nil
			}
			actual++
		}
		if actual != expected {
			return false, nil
		}
	}
	return true, nil
}

func nftPrefix(value string) (map[string]any, error) {
	parts := strings.Split(value, "/")
	if len(parts) != 2 || parts[0] == "" {
		return nil, ErrUnsupportedInput
	}
	length, err := strconv.ParseUint(parts[1], 10, 8)
	if err != nil {
		return nil, ErrUnsupportedInput
	}
	return map[string]any{"prefix": map[string]any{"addr": parts[0], "len": float64(length)}}, nil
}

func nftIPMatch(field string, right any) map[string]any {
	return map[string]any{"match": map[string]any{
		"op": "==", "left": map[string]any{"payload": map[string]any{"protocol": "ip", "field": field}}, "right": right,
	}}
}

func nftVerdict(expr []any, verdict string) bool {
	for _, value := range expr {
		if _, ok := value.(map[string]any)[verdict]; ok {
			return true
		}
	}
	return false
}

func nftUnconditionalAccept(expr []any) bool {
	if len(expr) == 0 || !reflect.DeepEqual(expr[len(expr)-1], map[string]any{"accept": nil}) {
		return false
	}
	for _, value := range expr[:len(expr)-1] {
		if _, ok := value.(map[string]any)["match"]; ok {
			return false
		}
	}
	return true
}

func hasAnyKey(value map[string]any, keys ...string) bool {
	for _, key := range keys {
		if _, ok := value[key]; ok {
			return true
		}
	}
	return false
}
