package wizard

import (
	"fmt"
	"math/big"
	"strings"
)

var auditRecentFields = []struct {
	name  string
	limit int
}{
	{"ts", 32},
	{"id", 36},
	{"actor", 64},
	{"action", 16},
	{"status", 32},
	{"keys", 400},
}

func auditRecent(arguments *ConfigValue) (*ConfigValue, error) {
	entriesValue, err := auditField(arguments, "entries")
	if err != nil {
		return nil, err
	}
	limitValue, err := auditField(arguments, "limit")
	if err != nil {
		return nil, err
	}
	if entriesValue.Kind != "list" {
		return nil, configTypeError{"entries must be a list"}
	}
	entries := make([]*ConfigValue, 0, len(entriesValue.Items))
	for _, entry := range entriesValue.Items {
		if entry == nil || entry.Kind != "dict" {
			return nil, configAttributeError{fmt.Sprintf("'%s' object has no attribute 'get'", configPythonType(entry))}
		}
		fields := make([]ConfigField, 0, len(auditRecentFields))
		for _, field := range auditRecentFields {
			value, ok := entry.Field(field.name)
			if !ok {
				value = configString("")
			}
			clean, cleanErr := auditClean(value, field.limit)
			if cleanErr != nil {
				return nil, cleanErr
			}
			fields = append(fields, ConfigField{Key: field.name, Value: configString(clean)})
		}
		entries = append(entries, editorDict(fields...))
	}
	end, err := auditSliceEnd(limitValue, len(entries))
	if err != nil {
		return nil, err
	}
	result := make([]*ConfigValue, end)
	for index := 0; index < end; index++ {
		result[index] = entries[len(entries)-1-index]
	}
	return &ConfigValue{Kind: "list", Items: result}, nil
}

func auditMirror(arguments *ConfigValue) (*ConfigValue, error) {
	entries, err := auditField(arguments, "entries")
	if err != nil {
		return nil, err
	}
	if entries.Kind != "list" {
		return nil, configTypeError{"entries must be a list"}
	}
	result := make([]*ConfigValue, 0, len(entries.Items))
	for index := len(entries.Items) - 1; index >= 0; index-- {
		entry := entries.Items[index]
		if entry == nil || entry.Kind != "dict" {
			return nil, configAttributeError{fmt.Sprintf("'%s' object has no attribute 'get'", configPythonType(entry))}
		}
		id := auditEntryValue(entry, "id")
		if !id.PythonTruth() {
			continue
		}
		if id.Kind != "str" {
			return nil, configTypeError{"audit fields must be strings"}
		}
		ts, fieldErr := auditMirrorField(entry, "ts")
		if fieldErr != nil {
			return nil, fieldErr
		}
		actor, fieldErr := auditMirrorField(entry, "actor")
		if fieldErr != nil {
			return nil, fieldErr
		}
		action, fieldErr := auditMirrorField(entry, "action")
		if fieldErr != nil {
			return nil, fieldErr
		}
		status, fieldErr := auditMirrorField(entry, "status")
		if fieldErr != nil {
			return nil, fieldErr
		}
		keys, fieldErr := auditMirrorField(entry, "keys")
		if fieldErr != nil {
			return nil, fieldErr
		}
		result = append(result, editorDict(
			editorField("id", id),
			editorField("ts", ts),
			editorField("source", configString("control")),
			editorField("actor", actor),
			editorField("action", action),
			editorField("status", status),
			editorField("keys", keys),
		))
	}
	return &ConfigValue{Kind: "list", Items: result}, nil
}

func auditMirrorField(entry *ConfigValue, name string) (*ConfigValue, error) {
	value := auditEntryValue(entry, name)
	if value.Kind != "str" {
		return nil, configTypeError{"audit fields must be strings"}
	}
	return value, nil
}

func auditEntryValue(entry *ConfigValue, name string) *ConfigValue {
	if value, ok := entry.Field(name); ok {
		return value
	}
	return configString("")
}

func auditSliceEnd(limit *ConfigValue, length int) (int, error) {
	if limit == nil || limit.Kind == "null" {
		return length, nil
	}
	var value *big.Int
	switch limit.Kind {
	case "bool":
		if limit.Bool {
			value = big.NewInt(1)
		} else {
			value = new(big.Int)
		}
	case "int":
		value, _ = new(big.Int).SetString(limit.Text, 10)
	default:
		return 0, configTypeError{"slice indices must be integers or None or have an __index__ method"}
	}
	size := big.NewInt(int64(length))
	if value.Sign() >= 0 {
		if value.Cmp(size) >= 0 {
			return length, nil
		}
		return int(value.Int64()), nil
	}
	value = new(big.Int).Add(size, value)
	if value.Sign() <= 0 {
		return 0, nil
	}
	return int(value.Int64()), nil
}

func auditClean(value *ConfigValue, limit int) (string, error) {
	if value == nil || value.Kind != "str" {
		return "", configTypeError{"audit fields must be strings"}
	}
	var clean strings.Builder
	for _, char := range value.Text {
		if auditSafe(char) {
			clean.WriteRune(char)
			if clean.Len() == limit {
				break
			}
		}
	}
	return clean.String(), nil
}

func auditSafe(char rune) bool {
	return char >= 'A' && char <= 'Z' || char >= 'a' && char <= 'z' || char >= '0' && char <= '9' || strings.ContainsRune(" ._:;/@?&=%+#-", char)
}
