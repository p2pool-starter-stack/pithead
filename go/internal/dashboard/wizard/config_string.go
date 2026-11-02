package wizard

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"unicode/utf8"
)

func configWireString(value string) any {
	if utf8.ValidString(value) {
		return value
	}
	return []any{"str-bytes", base64.StdEncoding.EncodeToString([]byte(value))}
}

func decodeConfigString(raw json.RawMessage) (string, error) {
	raw = bytes.TrimSpace(raw)
	var value string
	if len(raw) != 0 && raw[0] == '"' && json.Unmarshal(raw, &value) == nil {
		return value, nil
	}
	var tagged []json.RawMessage
	if json.Unmarshal(raw, &tagged) != nil || len(tagged) != 2 {
		return "", fmt.Errorf("invalid config string")
	}
	var kind string
	if json.Unmarshal(tagged[0], &kind) != nil || kind != "str-bytes" || len(tagged[1]) == 0 || tagged[1][0] != '"' || json.Unmarshal(tagged[1], &value) != nil {
		return "", fmt.Errorf("invalid config string")
	}
	decoded, err := base64.StdEncoding.DecodeString(value)
	if err != nil {
		return "", fmt.Errorf("invalid encoded config string")
	}
	return string(decoded), nil
}

func configStrings(values []string) *ConfigValue {
	items := make([]*ConfigValue, 0, len(values))
	for _, value := range values {
		items = append(items, &ConfigValue{Kind: "str", Text: value})
	}
	return &ConfigValue{Kind: "list", Items: items}
}
