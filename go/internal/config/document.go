package config

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"strings"
	"unicode/utf8"
)

var ErrUnsupportedDocument = errors.New("unsupported config document")

var errInvalidDocument = errors.New("invalid config document")

const maxDocumentDepth = 128

type Document struct {
	root node
}

type node struct {
	value  any
	object []member
	array  []node
}

type member struct {
	key   string
	value node
}

func ParseDocument(raw []byte) (*Document, error) {
	if !utf8.Valid(raw) || hasSurrogateEscape(raw) {
		return nil, ErrUnsupportedDocument
	}

	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.UseNumber()
	root, err := parseNode(decoder, 0)
	if err != nil {
		return nil, parseDocumentError(raw, err)
	}
	if _, err := decoder.Token(); !errors.Is(err, io.EOF) {
		return nil, parseDocumentError(raw, errInvalidDocument)
	}
	return &Document{root: root}, nil
}

func parseNode(decoder *json.Decoder, depth int) (node, error) {
	token, err := decoder.Token()
	if err != nil {
		return node{}, errInvalidDocument
	}
	delim, compound := token.(json.Delim)
	if !compound {
		if number, ok := token.(json.Number); ok && oversizedInteger(number) {
			return node{}, ErrUnsupportedDocument
		}
		return node{value: token}, nil
	}
	if depth >= maxDocumentDepth {
		return node{}, ErrUnsupportedDocument
	}

	switch delim {
	case '{':
		object := make([]member, 0)
		for decoder.More() {
			keyToken, err := decoder.Token()
			if err != nil {
				return node{}, errInvalidDocument
			}
			key, ok := keyToken.(string)
			if !ok {
				return node{}, errInvalidDocument
			}
			value, err := parseNode(decoder, depth+1)
			if err != nil {
				return node{}, err
			}
			object = append(object, member{key: key, value: value})
		}
		if token, err = decoder.Token(); err != nil || token != json.Delim('}') {
			return node{}, errInvalidDocument
		}
		return node{object: object}, nil
	case '[':
		array := make([]node, 0)
		for decoder.More() {
			value, err := parseNode(decoder, depth+1)
			if err != nil {
				return node{}, err
			}
			array = append(array, value)
		}
		if token, err = decoder.Token(); err != nil || token != json.Delim(']') {
			return node{}, errInvalidDocument
		}
		return node{array: array}, nil
	default:
		return node{}, errInvalidDocument
	}
}

func parseDocumentError(raw []byte, err error) error {
	if errors.Is(err, ErrUnsupportedDocument) || bytes.Contains(raw, []byte("NaN")) || bytes.Contains(raw, []byte("Infinity")) {
		return ErrUnsupportedDocument
	}
	return errInvalidDocument
}

func oversizedInteger(number json.Number) bool {
	value := number.String()
	if strings.ContainsAny(value, ".eE") {
		return false
	}
	if strings.HasPrefix(value, "-") {
		value = value[1:]
	}
	return len(value) > 4096
}

func (document *Document) ValidationError(request bool) string {
	if document == nil {
		return ""
	}
	if reason := duplicateError(document.root, ""); reason != "" {
		return reason
	}
	candidate := document.root
	if request && document.root.object != nil {
		candidate = node{object: []member{}}
		for _, item := range document.root.object {
			if item.key == "config" {
				candidate = item.value
				break
			}
		}
	}
	return placeholderError(candidate, "")
}

func duplicateError(current node, path string) string {
	if current.object != nil {
		seen := make(map[string]struct{}, len(current.object))
		for _, item := range current.object {
			if _, exists := seen[item.key]; exists {
				location := path
				if location == "" {
					location = "the top level"
				}
				return fmt.Sprintf("duplicate key %s at %s (path %s)", asciiJSONString(item.key, false), location, joinPath(path, item.key))
			}
			seen[item.key] = struct{}{}
			if reason := duplicateError(item.value, joinPath(path, item.key)); reason != "" {
				return reason
			}
		}
		return ""
	}
	for index, item := range current.array {
		if reason := duplicateError(item, fmt.Sprintf("%s[%d]", path, index)); reason != "" {
			return reason
		}
	}
	return ""
}

func placeholderError(current node, path string) string {
	if current.object != nil {
		for _, item := range current.object {
			if reason := placeholderError(item.value, joinPath(path, item.key)); reason != "" {
				return reason
			}
		}
		return ""
	}
	if current.array != nil {
		for index, item := range current.array {
			if reason := placeholderError(item, fmt.Sprintf("%s[%d]", path, index)); reason != "" {
				return reason
			}
		}
		return ""
	}
	value, ok := current.value.(string)
	if !ok {
		return ""
	}
	upper := strings.ToUpper(strings.NewReplacer("\ufb05", "st", "\ufb06", "st").Replace(value))
	if !strings.HasPrefix(upper, "PASTE_") && !strings.HasPrefix(upper, "YOUR_") {
		return ""
	}
	if path == "" {
		path = "the top level"
	}
	return "placeholder value at " + path
}

func ValidateDocumentFile(path string, request bool) (string, error) {
	if strings.IndexByte(path, 0) >= 0 {
		return "", ErrUnsupportedDocument
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		return "could not read config document", nil
	}
	document, err := ParseDocument(raw)
	if errors.Is(err, ErrUnsupportedDocument) {
		return "", err
	}
	if err != nil {
		return "not valid JSON", nil
	}
	return document.ValidationError(request), nil
}

func joinPath(parent, key string) string {
	key = asciiJSONString(key, true)
	if parent == "" {
		return key
	}
	return parent + "." + key
}

func asciiJSONString(value string, path bool) string {
	var result strings.Builder
	if !path {
		result.WriteByte('"')
	}
	for _, current := range value {
		switch current {
		case '"':
			if !path {
				result.WriteByte('\\')
			}
			result.WriteByte('"')
		case '\\':
			result.WriteString(`\\`)
		case '\b':
			result.WriteString(`\b`)
		case '\f':
			result.WriteString(`\f`)
		case '\n':
			result.WriteString(`\n`)
		case '\r':
			result.WriteString(`\r`)
		case '\t':
			result.WriteString(`\t`)
		default:
			switch {
			case current < 0x20 || current == 0x7f:
				fmt.Fprintf(&result, `\u%04x`, current)
			case current <= 0x7f:
				result.WriteRune(current)
			case current <= 0xffff:
				fmt.Fprintf(&result, `\u%04x`, current)
			default:
				current -= 0x10000
				fmt.Fprintf(&result, `\u%04x\u%04x`, 0xd800+(current>>10), 0xdc00+(current&0x3ff))
			}
		}
	}
	if !path {
		result.WriteByte('"')
	}
	return result.String()
}

func hasSurrogateEscape(raw []byte) bool {
	for index := 0; index+5 < len(raw); index++ {
		if raw[index] != '\\' || raw[index+1] != 'u' && raw[index+1] != 'U' || raw[index+2] != 'd' && raw[index+2] != 'D' {
			continue
		}
		if (raw[index+3] >= '8' && raw[index+3] <= '9') || (raw[index+3] >= 'a' && raw[index+3] <= 'f') || (raw[index+3] >= 'A' && raw[index+3] <= 'F') {
			return true
		}
	}
	return false
}
