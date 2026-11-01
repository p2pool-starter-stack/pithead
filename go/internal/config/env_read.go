package config

import (
	"bytes"
	"strings"
)

const directoryLineBreakReason = "Directory values in .env must not contain CR or LF."

func DecodeEnvValue(value, key string) (string, string) {
	if len(value) >= 2 && value[0] == '"' && value[len(value)-1] == '"' {
		value = decodeQuotedEnvValue(value[1 : len(value)-1])
	}
	if len(key) >= 4 && key[len(key)-4:] == "_DIR" && strings.ContainsAny(value, "\r\n") {
		return value, directoryLineBreakReason
	}
	return value, ""
}

func EnvGetFile(raw []byte, key string) (string, string, bool) {
	if !validLiteralEnvKey(key) || bytes.IndexByte(raw, 0) >= 0 {
		return "", "", false
	}
	prefix := []byte(key + "=")
	for len(raw) > 0 {
		line := raw
		if index := bytes.IndexByte(raw, '\n'); index >= 0 {
			line = raw[:index]
			raw = raw[index+1:]
		} else {
			raw = nil
		}
		if bytes.HasPrefix(line, prefix) {
			value, reason := DecodeEnvValue(string(line[len(prefix):]), key)
			return value, reason, true
		}
	}
	return "", "", true
}

func decodeQuotedEnvValue(value string) string {
	output := make([]byte, 0, len(value))
	for index := 0; index < len(value); index++ {
		current := value[index]
		if current == '\\' && index+1 < len(value) {
			index++
			current = value[index]
			switch current {
			case 'n':
				current = '\n'
			case 'r':
				current = '\r'
			case 't':
				current = '\t'
			}
		} else if current == '$' && index+1 < len(value) && value[index+1] == '$' {
			index++
		}
		output = append(output, current)
	}
	return string(output)
}

func validLiteralEnvKey(key string) bool {
	if key == "" || key[0] != '_' && !asciiLetter(key[0]) {
		return false
	}
	for index := 1; index < len(key); index++ {
		if key[index] != '_' && !asciiLetter(key[index]) && (key[index] < '0' || key[index] > '9') {
			return false
		}
	}
	return true
}

func asciiLetter(value byte) bool {
	return value >= 'A' && value <= 'Z' || value >= 'a' && value <= 'z'
}
