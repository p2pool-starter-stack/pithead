package wizard

import (
	"bytes"
	"encoding/json"
)

type objectField struct {
	key   string
	value json.RawMessage
}

type rawObject struct {
	fields []objectField
}

func emptyObject() rawObject { return rawObject{} }

func parseObject(input []byte) (rawObject, bool) {
	if !validRelaxedJSON(input) {
		return rawObject{}, false
	}
	decoder := json.NewDecoder(bytes.NewReader(replaceNonFinite(input)))
	decoder.UseNumber()
	var decoded any
	if decoder.Decode(&decoded) != nil {
		return rawObject{}, false
	}
	if _, ok := decoded.(map[string]any); !ok {
		return rawObject{}, false
	}
	index := skipSpace(input, 1)
	fields := []objectField{}
	for index < len(input) && input[index] != '}' {
		keyStart := index
		keyEnd, ok := scanString(input, keyStart)
		if !ok {
			return rawObject{}, false
		}
		var key string
		if json.Unmarshal(input[keyStart:keyEnd], &key) != nil {
			return rawObject{}, false
		}
		index = skipSpace(input, keyEnd)
		if index >= len(input) || input[index] != ':' {
			return rawObject{}, false
		}
		index = skipSpace(input, index+1)
		end, ok := scanValue(input, index)
		if !ok {
			return rawObject{}, false
		}
		value := append(json.RawMessage(nil), input[index:end]...)
		replaced := false
		for fieldIndex := range fields {
			if fields[fieldIndex].key == key {
				fields[fieldIndex].value = value
				replaced = true
				break
			}
		}
		if !replaced {
			fields = append(fields, objectField{key: key, value: value})
		}
		index = skipSpace(input, end)
		if index < len(input) && input[index] == ',' {
			index = skipSpace(input, index+1)
		}
	}
	return rawObject{fields: fields}, true
}

func (o rawObject) raw() json.RawMessage { return o.without(func(string) bool { return false }) }

func (o rawObject) without(drop func(string) bool) json.RawMessage {
	output := []byte{'{'}
	first := true
	for _, field := range o.fields {
		if drop(field.key) {
			continue
		}
		if !first {
			output = append(output, ',')
		}
		key, _ := json.Marshal(field.key)
		output = append(output, key...)
		output = append(output, ':')
		output = append(output, field.value...)
		first = false
	}
	return append(output, '}')
}

func (o rawObject) stringValue(name string) (string, bool) {
	for i := len(o.fields) - 1; i >= 0; i-- {
		if o.fields[i].key != name {
			continue
		}
		var value string
		if json.Unmarshal(o.fields[i].value, &value) != nil {
			return "", false
		}
		return value, true
	}
	return "", false
}

func validRelaxedJSON(input []byte) bool { return json.Valid(replaceNonFinite(input)) }

func replaceNonFinite(input []byte) []byte {
	output := append([]byte(nil), input...)
	inString := false
	escaped := false
	for index := 0; index < len(output); index++ {
		if inString {
			if escaped {
				escaped = false
			} else if output[index] == '\\' {
				escaped = true
			} else if output[index] == '"' {
				inString = false
			}
			continue
		}
		if output[index] == '"' {
			inString = true
			continue
		}
		for _, token := range [][]byte{[]byte("-Infinity"), []byte("Infinity"), []byte("NaN")} {
			if bytes.HasPrefix(output[index:], token) {
				output[index] = '0'
				for offset := 1; offset < len(token); offset++ {
					output[index+offset] = ' '
				}
				index += len(token) - 1
				break
			}
		}
	}
	return output
}

func scanValue(input []byte, start int) (int, bool) {
	if start >= len(input) {
		return 0, false
	}
	if input[start] == '"' {
		return scanString(input, start)
	}
	depth := 0
	inString := false
	escaped := false
	for index := start; index < len(input); index++ {
		char := input[index]
		if inString {
			if escaped {
				escaped = false
			} else if char == '\\' {
				escaped = true
			} else if char == '"' {
				inString = false
			}
			continue
		}
		switch char {
		case '"':
			inString = true
		case '{', '[':
			depth++
		case '}', ']':
			if depth == 0 {
				return trimSpaceEnd(input, start, index), true
			}
			depth--
		case ',':
			if depth == 0 {
				return trimSpaceEnd(input, start, index), true
			}
		}
	}
	return trimSpaceEnd(input, start, len(input)), !inString && depth == 0
}

func scanString(input []byte, start int) (int, bool) {
	escaped := false
	for index := start + 1; index < len(input); index++ {
		if escaped {
			escaped = false
		} else if input[index] == '\\' {
			escaped = true
		} else if input[index] == '"' {
			return index + 1, true
		}
	}
	return 0, false
}

func skipSpace(input []byte, index int) int {
	for index < len(input) && (input[index] == ' ' || input[index] == '\n' || input[index] == '\r' || input[index] == '\t') {
		index++
	}
	return index
}

func trimSpaceEnd(input []byte, start, end int) int {
	for end > start && (input[end-1] == ' ' || input[end-1] == '\n' || input[end-1] == '\r' || input[end-1] == '\t') {
		end--
	}
	return end
}
