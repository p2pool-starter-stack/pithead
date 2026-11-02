package wizard

import (
	"fmt"
	"strings"
	"unicode/utf8"
)

func documentFieldPath(parent string, key, keyJSON *ConfigValue) (string, error) {
	dumped, err := documentDump(key, keyJSON)
	if err != nil {
		return "", err
	}
	start, end := 1, len(dumped)-1
	escaped := ""
	if end >= start {
		escaped = dumped[start:end]
	}
	escaped = strings.ReplaceAll(escaped, `\"`, `"`)
	if parent == "" {
		return escaped, nil
	}
	return parent + "." + escaped, nil
}

func documentPath(parent, key string) (string, error) {
	return documentFieldPath(parent, documentText(key), nil)
}

func documentDump(key, keyJSON *ConfigValue) (string, error) {
	if keyJSON != nil {
		return documentString(keyJSON, "key_json")
	}
	value, err := documentString(key, "key")
	if err != nil {
		return "", err
	}
	return documentJSONString(value)
}

func documentString(value *ConfigValue, name string) (string, error) {
	if value == nil || value.Kind != "str" {
		return "", ValidationError{Message: name + " must be a string"}
	}
	return value.Text, nil
}

func optionalDocumentPath(value *ConfigValue) (string, error) {
	if value == nil {
		return "", nil
	}
	return documentString(value, "path")
}

func documentText(value string) *ConfigValue {
	return &ConfigValue{Kind: "str", Text: value}
}

func documentJSONString(value string) (string, error) {
	var result strings.Builder
	result.WriteByte('"')
	for len(value) != 0 {
		r, size := utf8.DecodeRuneInString(value)
		if r == utf8.RuneError && size == 1 {
			if len(value) < 3 || value[0] != 0xed || value[1]&0xe0 != 0xa0 || value[2]&0xc0 != 0x80 {
				return "", ValidationError{Message: "invalid document string"}
			}
			r = rune(value[0]&0x0f)<<12 | rune(value[1]&0x3f)<<6 | rune(value[2]&0x3f)
			size = 3
		}
		value = value[size:]
		switch r {
		case '\b':
			result.WriteString(`\b`)
		case '\t':
			result.WriteString(`\t`)
		case '\n':
			result.WriteString(`\n`)
		case '\f':
			result.WriteString(`\f`)
		case '\r':
			result.WriteString(`\r`)
		case '"':
			result.WriteString(`\"`)
		case '\\':
			result.WriteString(`\\`)
		default:
			switch {
			case r >= 0x20 && r <= 0x7e:
				result.WriteRune(r)
			case r <= 0xffff:
				fmt.Fprintf(&result, `\u%04x`, r)
			default:
				r -= 0x10000
				fmt.Fprintf(&result, `\u%04x\u%04x`, 0xd800+(r>>10), 0xdc00+(r&0x3ff))
			}
		}
	}
	result.WriteByte('"')
	return result.String(), nil
}
