package config

import (
	"bytes"
	"encoding/json"
	"strconv"
	"unicode/utf8"
)

const maxJQInteger = int64(9007199254740991)

func prettyJQ(root node) ([]byte, error) {
	var output bytes.Buffer
	if err := writeJQJSON(&output, root, 0); err != nil {
		return nil, err
	}
	output.WriteByte('\n')
	return output.Bytes(), nil
}

func rawJQ(root node) ([]byte, error) {
	if root.object == nil && root.array == nil {
		if value, ok := root.value.(string); ok {
			if !utf8.ValidString(value) {
				return nil, ErrUnsupportedDefaults
			}
			output := make([]byte, 0, len(value)+1)
			output = append(output, value...)
			return append(output, '\n'), nil
		}
	}
	return prettyJQ(root)
}

func writeJQJSON(output *bytes.Buffer, current node, depth int) error {
	if current.object != nil {
		if current.array != nil || current.value != nil {
			return ErrUnsupportedDefaults
		}
		if len(current.object) == 0 {
			output.WriteString("{}")
			return nil
		}
		output.WriteString("{\n")
		for index, item := range current.object {
			writeJQIndent(output, depth+1)
			if err := writeJQString(output, item.key); err != nil {
				return err
			}
			output.WriteString(": ")
			if err := writeJQJSON(output, item.value, depth+1); err != nil {
				return err
			}
			if index+1 < len(current.object) {
				output.WriteByte(',')
			}
			output.WriteByte('\n')
		}
		writeJQIndent(output, depth)
		output.WriteByte('}')
		return nil
	}

	if current.array != nil {
		if current.value != nil {
			return ErrUnsupportedDefaults
		}
		if len(current.array) == 0 {
			output.WriteString("[]")
			return nil
		}
		output.WriteString("[\n")
		for index, item := range current.array {
			writeJQIndent(output, depth+1)
			if err := writeJQJSON(output, item, depth+1); err != nil {
				return err
			}
			if index+1 < len(current.array) {
				output.WriteByte(',')
			}
			output.WriteByte('\n')
		}
		writeJQIndent(output, depth)
		output.WriteByte(']')
		return nil
	}

	switch value := current.value.(type) {
	case nil:
		output.WriteString("null")
	case string:
		return writeJQString(output, value)
	case bool:
		output.WriteString(strconv.FormatBool(value))
	case json.Number:
		if !validJQInteger(value.String()) {
			return ErrUnsupportedDefaults
		}
		output.WriteString(value.String())
	default:
		return ErrUnsupportedDefaults
	}
	return nil
}

func validJQInteger(value string) bool {
	if value == "0" {
		return true
	}
	digits := value
	if len(digits) > 1 && digits[0] == '-' {
		digits = digits[1:]
	}
	if len(digits) == 0 || digits[0] < '1' || digits[0] > '9' {
		return false
	}
	for _, digit := range digits[1:] {
		if digit < '0' || digit > '9' {
			return false
		}
	}
	parsed, err := strconv.ParseInt(value, 10, 64)
	return err == nil && parsed >= -maxJQInteger && parsed <= maxJQInteger
}

func writeJQString(output *bytes.Buffer, value string) error {
	if !utf8.ValidString(value) {
		return ErrUnsupportedDefaults
	}
	const hex = "0123456789abcdef"
	output.WriteByte('"')
	for _, current := range value {
		switch current {
		case '"', '\\':
			output.WriteByte('\\')
			output.WriteRune(current)
		case '\b':
			output.WriteString(`\b`)
		case '\t':
			output.WriteString(`\t`)
		case '\n':
			output.WriteString(`\n`)
		case '\f':
			output.WriteString(`\f`)
		case '\r':
			output.WriteString(`\r`)
		default:
			if current < 0x20 || current == 0x7f {
				output.WriteString(`\u00`)
				output.WriteByte(hex[byte(current)>>4])
				output.WriteByte(hex[byte(current)&0x0f])
			} else {
				output.WriteRune(current)
			}
		}
	}
	output.WriteByte('"')
	return nil
}

func writeJQIndent(output *bytes.Buffer, depth int) {
	for range depth {
		output.WriteString("  ")
	}
}
