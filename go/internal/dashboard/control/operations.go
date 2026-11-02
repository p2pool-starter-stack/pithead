package control

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"unicode/utf8"

	"github.com/google/uuid"
)

var editorMetadata = map[string]struct{}{
	"_config_version_newer": {},
	"_core_keys":            {},
	"_editable_keys":        {},
	"_confirm_keys":         {},
	"_approval_keys":        {},
	"_default_keys":         {},
	"_last_apply":           {},
}

var workerWritable = map[string]struct{}{
	"pools": {}, "DONATION": {}, "autotune": {}, "watchdog": {},
	"watchdog_interval_min": {}, "max_temp_c": {},
}

func WorkerWritableKey(key string) bool {
	_, ok := workerWritable[key]
	return ok
}

type pair [2]any

func submit(command Request) (any, error) {
	id, err := requestID(command.ID)
	if err != nil {
		return nil, err
	}
	actor := command.Actor
	if len(actor) == 0 {
		actor = json.RawMessage(`""`)
	}
	switch command.Kind {
	case "", "generic":
		result := []pair{{"id", id}, {"action", command.Action}, {"actor", actor}}
		if present(command.Config) {
			config, err := stripMetadata(command.Config)
			if err != nil {
				return nil, err
			}
			result = append(result, pair{"config", config})
		}
		result = appendOptional(result, "version", command.Version)
		result = appendOptional(result, "confirm", command.Confirm)
		result = appendOptional(result, "approval", command.Approval)
		return result, nil
	case "worker-apply":
		return []pair{{"id", id}, {"action", "worker-apply"}, {"actor", actor}, {"worker", command.Worker}, {"changes", command.Changes}}, nil
	case "worker-upgrade":
		return []pair{{"id", id}, {"action", "worker-upgrade"}, {"actor", actor}, {"worker", command.Worker}, {"version", command.Version}}, nil
	default:
		return nil, valueError("unsupported control submit kind: %s", command.Kind)
	}
}

func appendOptional(values []pair, key string, value json.RawMessage) []pair {
	if present(value) {
		return append(values, pair{key, value})
	}
	return values
}

func present(value json.RawMessage) bool {
	return len(value) != 0 && string(value) != "null"
}

func stripMetadata(raw json.RawMessage) (json.RawMessage, error) {
	decoder := json.NewDecoder(bytes.NewReader(raw))
	token, err := decoder.Token()
	if err != nil || token != json.Delim('{') {
		return raw, nil
	}
	var output bytes.Buffer
	output.WriteByte('{')
	first := true
	for decoder.More() {
		keyToken, err := decoder.Token()
		if err != nil {
			return nil, valueError("%s", err)
		}
		key, ok := keyToken.(string)
		if !ok {
			return nil, valueError("config object key is not a string")
		}
		var value json.RawMessage
		if err := decoder.Decode(&value); err != nil {
			return nil, valueError("%s", err)
		}
		if _, remove := editorMetadata[key]; remove {
			continue
		}
		if !first {
			output.WriteByte(',')
		}
		encodedKey, _ := json.Marshal(key)
		output.Write(encodedKey)
		output.WriteByte(':')
		output.Write(value)
		first = false
	}
	if _, err := decoder.Token(); err != nil {
		return nil, valueError("%s", err)
	}
	output.WriteByte('}')
	return output.Bytes(), nil
}

func validateWorker(raw json.RawMessage) string {
	var changes map[string]json.RawMessage
	if err := json.Unmarshal(raw, &changes); err != nil || len(changes) == 0 {
		return "changes must be a non-empty object of writable config keys"
	}
	bad := make([]string, 0)
	for key := range changes {
		if _, ok := workerWritable[key]; !ok {
			bad = append(bad, key)
		}
	}
	if len(bad) == 0 {
		return ""
	}
	sort.Strings(bad)
	message := "keys not writable via the control path: "
	for index, key := range bad {
		if index != 0 {
			message += ", "
		}
		message += key
	}
	return message
}

func readResult(directory, id string) (any, error) {
	normalized, err := normalizeID(id)
	if err != nil {
		return nil, err
	}
	data, readErr := os.ReadFile(filepath.Join(directory, normalized+".json"))
	if readErr != nil {
		return nil, nil
	}
	if !utf8.Valid(data) {
		position := 0
		for position < len(data) {
			_, size := utf8.DecodeRune(data[position:])
			if size == 1 {
				break
			}
			position += size
		}
		message := fmt.Sprintf("'utf-8' codec can't decode byte 0x%02x in position %d: invalid start byte", data[position], position)
		return nil, newError("UnicodeDecodeError", message, nil)
	}
	return string(data), nil
}

func requestID(id string) (string, error) {
	if id == "" {
		return uuid.NewString(), nil
	}
	return normalizeID(id)
}

func normalizeID(id string) (string, error) {
	hex := strings.ReplaceAll(strings.ReplaceAll(id, "urn:", ""), "uuid:", "")
	hex = strings.ReplaceAll(strings.Trim(hex, "{}"), "-", "")
	if len(hex) != 32 {
		return "", valueError("badly formed hexadecimal UUID string")
	}
	digits := hex
	if strings.HasPrefix(digits, "+") {
		digits = digits[1:]
	} else if strings.HasPrefix(digits, "-") {
		return "", valueError("badly formed hexadecimal UUID string")
	}
	if strings.HasPrefix(digits, "0x") || strings.HasPrefix(digits, "0X") {
		digits = digits[2:]
	}
	hex = strings.Repeat("0", 32-len(digits)) + digits
	parsed, err := uuid.Parse(hex)
	if err != nil {
		return "", valueError("badly formed hexadecimal UUID string")
	}
	return parsed.String(), nil
}
