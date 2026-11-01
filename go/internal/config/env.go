package config

import (
	"errors"
	"strings"
	"unicode"
	"unicode/utf8"
)

var ErrUnsupportedEnv = errors.New("unsupported dotenv render")

type EnvPair struct {
	Key   string
	Value string
}

func RenderEnv(pairs []EnvPair) ([]byte, error) {
	if len(pairs) == 0 {
		return nil, ErrUnsupportedEnv
	}
	seen := make(map[string]struct{}, len(pairs))
	for _, pair := range pairs {
		if !validEnvKey(pair.Key) || !supportedEnvValue(pair.Value) {
			return nil, ErrUnsupportedEnv
		}
		if _, exists := seen[pair.Key]; exists {
			return nil, ErrUnsupportedEnv
		}
		seen[pair.Key] = struct{}{}
	}

	var output strings.Builder
	for _, pair := range pairs {
		output.WriteString(pair.Key)
		output.WriteByte('=')
		output.WriteString(renderEnvValue(pair.Value))
		output.WriteByte('\n')
	}
	return []byte(output.String()), nil
}

func validEnvKey(key string) bool {
	if key == "" || key[0] != '_' && (key[0] < 'A' || key[0] > 'Z') {
		return false
	}
	for index := 1; index < len(key); index++ {
		current := key[index]
		if current != '_' && (current < 'A' || current > 'Z') && (current < '0' || current > '9') {
			return false
		}
	}
	return true
}

func supportedEnvValue(value string) bool {
	if !utf8.ValidString(value) || strings.IndexByte(value, 0) >= 0 {
		return false
	}
	for _, current := range value {
		if current >= utf8.RuneSelf && (unicode.IsSpace(current) || unicode.IsControl(current) || unicode.In(current, unicode.Cf)) {
			return false
		}
	}
	return true
}

func renderEnvValue(value string) string {
	if !envValueNeedsQuotes(value) {
		return value
	}
	var output strings.Builder
	output.WriteByte('"')
	for _, current := range []byte(value) {
		switch current {
		case '\\':
			output.WriteString(`\\`)
		case '"':
			output.WriteString(`\"`)
		case '$':
			output.WriteString("$$")
		case '\n':
			output.WriteString(`\n`)
		case '\r':
			output.WriteString(`\r`)
		case '\t':
			output.WriteString(`\t`)
		default:
			output.WriteByte(current)
		}
	}
	output.WriteByte('"')
	return output.String()
}

func envValueNeedsQuotes(value string) bool {
	if strings.ContainsAny(value, `$"'\\`) {
		return true
	}
	for index := 0; index < len(value); index++ {
		current := value[index]
		if current == '\t' || current == '\n' || current == '\r' {
			return true
		}
		if asciiEnvSpace(current) && (index == 0 || index == len(value)-1 || index+1 < len(value) && value[index+1] == '#') {
			return true
		}
	}
	return false
}

func asciiEnvSpace(value byte) bool {
	return value == ' ' || value == '\t' || value == '\n' || value == '\r' || value == '\f' || value == '\v'
}
