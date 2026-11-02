package wizard

import (
	"bytes"
	"encoding/json"
	"fmt"
	"math/big"
	"strconv"
)

type ConfigField struct {
	Key   string
	Value *ConfigValue
}

type ConfigValue struct {
	Kind     string
	Text     string
	Bool     bool
	Fields   []ConfigField
	Items    []*ConfigValue
	Identity int
}

func (v ConfigValue) MarshalJSON() ([]byte, error) {
	var payload any
	switch v.Kind {
	case "null":
		payload = []any{"null", nil}
	case "bool":
		payload = []any{"bool", v.Bool}
	case "int":
		if !validInteger(v.Text) {
			return nil, fmt.Errorf("invalid config integer %q", v.Text)
		}
		payload = []any{"int", v.Text}
	case "float":
		if _, err := parseFloat(v.Text); err != nil {
			return nil, err
		}
		if v.Identity == 0 {
			payload = []any{"float", v.Text}
		} else {
			payload = []any{"float", v.Text, v.Identity}
		}
	case "str":
		if text, ok := configWireString(v.Text).(string); ok {
			payload = []any{"str", text}
		} else {
			payload = configWireString(v.Text)
		}
	case "list":
		items := v.Items
		if items == nil {
			items = []*ConfigValue{}
		}
		for _, item := range items {
			if item == nil {
				return nil, fmt.Errorf("nil list config value")
			}
		}
		payload = []any{"list", items}
	case "dict":
		pairs := make([]any, 0, len(v.Fields))
		seen := make(map[string]struct{}, len(v.Fields))
		for _, field := range v.Fields {
			if field.Value == nil {
				return nil, fmt.Errorf("nil config value for %q", field.Key)
			}
			if _, ok := seen[field.Key]; ok {
				return nil, fmt.Errorf("duplicate config key %q", field.Key)
			}
			seen[field.Key] = struct{}{}
			pairs = append(pairs, []any{configWireString(field.Key), field.Value})
		}
		payload = []any{"dict", pairs}
	default:
		return nil, fmt.Errorf("invalid config kind %q", v.Kind)
	}
	return json.Marshal(payload)
}

func (v *ConfigValue) UnmarshalJSON(data []byte) error {
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.UseNumber()
	var tagged []json.RawMessage
	if err := decoder.Decode(&tagged); err != nil {
		return err
	}
	if len(tagged) < 2 {
		return fmt.Errorf("config value must be a tagged array")
	}
	var kind string
	if err := json.Unmarshal(tagged[0], &kind); err != nil {
		return fmt.Errorf("invalid config kind: %w", err)
	}
	value := ConfigValue{Kind: kind}
	switch kind {
	case "null":
		if len(tagged) != 2 || string(tagged[1]) != "null" {
			return fmt.Errorf("invalid null config value")
		}
	case "bool":
		if len(tagged) != 2 || json.Unmarshal(tagged[1], &value.Bool) != nil {
			return fmt.Errorf("invalid bool config value")
		}
	case "int":
		if len(tagged) != 2 || json.Unmarshal(tagged[1], &value.Text) != nil || !validInteger(value.Text) {
			return fmt.Errorf("invalid int config value")
		}
	case "float":
		if len(tagged) != 2 && len(tagged) != 3 {
			return fmt.Errorf("invalid float config value")
		}
		if json.Unmarshal(tagged[1], &value.Text) != nil {
			return fmt.Errorf("invalid float config value")
		}
		if _, err := parseFloat(value.Text); err != nil {
			return err
		}
		if len(tagged) == 3 {
			if err := json.Unmarshal(tagged[2], &value.Identity); err != nil || value.Identity < 0 {
				return fmt.Errorf("invalid float identity")
			}
		}
	case "str":
		if len(tagged) != 2 || json.Unmarshal(tagged[1], &value.Text) != nil {
			return fmt.Errorf("invalid string config value")
		}
	case "str-bytes":
		text, err := decodeConfigString(data)
		if err != nil {
			return err
		}
		value.Kind, value.Text = "str", text
	case "list":
		if len(tagged) != 2 || string(tagged[1]) == "null" || json.Unmarshal(tagged[1], &value.Items) != nil {
			return fmt.Errorf("invalid list config value")
		}
		for _, item := range value.Items {
			if item == nil {
				return fmt.Errorf("nil list config value")
			}
		}
	case "dict":
		if len(tagged) != 2 {
			return fmt.Errorf("invalid dict config value")
		}
		if string(tagged[1]) == "null" {
			return fmt.Errorf("invalid dict config value")
		}
		var pairs [][]json.RawMessage
		if err := json.Unmarshal(tagged[1], &pairs); err != nil {
			return fmt.Errorf("invalid dict config value")
		}
		seen := make(map[string]struct{}, len(pairs))
		for _, pair := range pairs {
			if len(pair) != 2 {
				return fmt.Errorf("invalid config field")
			}
			key, err := decodeConfigString(pair[0])
			var child ConfigValue
			if err != nil {
				return fmt.Errorf("invalid config key")
			}
			if _, ok := seen[key]; ok {
				return fmt.Errorf("duplicate config key %q", key)
			}
			if err := json.Unmarshal(pair[1], &child); err != nil {
				return err
			}
			seen[key] = struct{}{}
			value.Fields = append(value.Fields, ConfigField{Key: key, Value: &child})
		}
	default:
		return fmt.Errorf("invalid config kind %q", kind)
	}
	*v = value
	return nil
}

func (v *ConfigValue) Field(name string) (*ConfigValue, bool) {
	if v == nil || v.Kind != "dict" {
		return nil, false
	}
	for _, field := range v.Fields {
		if field.Key == name {
			return field.Value, true
		}
	}
	return nil, false
}

func (v *ConfigValue) Set(name string, value *ConfigValue) {
	for index := range v.Fields {
		if v.Fields[index].Key == name {
			v.Fields[index].Value = value
			return
		}
	}
	v.Fields = append(v.Fields, ConfigField{Key: name, Value: value})
}

func (v *ConfigValue) Delete(name string) (*ConfigValue, bool) {
	if v == nil || v.Kind != "dict" {
		return nil, false
	}
	for index, field := range v.Fields {
		if field.Key == name {
			v.Fields = append(v.Fields[:index], v.Fields[index+1:]...)
			return field.Value, true
		}
	}
	return nil, false
}

func (v *ConfigValue) Clone() *ConfigValue {
	if v == nil {
		return nil
	}
	clone := &ConfigValue{Kind: v.Kind, Text: v.Text, Bool: v.Bool, Identity: v.Identity}
	clone.Items = make([]*ConfigValue, len(v.Items))
	for index, item := range v.Items {
		clone.Items[index] = item.Clone()
	}
	clone.Fields = make([]ConfigField, len(v.Fields))
	for index, field := range v.Fields {
		clone.Fields[index] = ConfigField{Key: field.Key, Value: field.Value.Clone()}
	}
	return clone
}

func (v *ConfigValue) Equal(other *ConfigValue) bool {
	return configEqual(v, other, false)
}

func (v *ConfigValue) PythonTruth() bool {
	if v == nil {
		return false
	}
	switch v.Kind {
	case "null":
		return false
	case "bool":
		return v.Bool
	case "int":
		integer, ok := new(big.Int).SetString(v.Text, 10)
		return ok && integer.Sign() != 0
	case "float":
		value, err := parseFloat(v.Text)
		return err == nil && value != 0
	case "str":
		return v.Text != ""
	case "list":
		return len(v.Items) != 0
	case "dict":
		return len(v.Fields) != 0
	default:
		return false
	}
}

func validInteger(text string) bool {
	if text == "" || text[0] == '+' || (len(text) > 1 && text[0] == '0') || (len(text) > 1 && text[0] == '-' && text[1] == '0') {
		return text == "0"
	}
	_, ok := new(big.Int).SetString(text, 10)
	return ok
}

func parseFloat(text string) (float64, error) {
	value, err := strconv.ParseFloat(text, 64)
	if err != nil {
		return 0, fmt.Errorf("invalid config float %q", text)
	}
	return value, nil
}
