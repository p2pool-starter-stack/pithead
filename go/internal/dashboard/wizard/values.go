package wizard

import (
	"fmt"
	"os"
	"strings"
)

type ValuesRequest struct {
	Operation string          `json:"operation"`
	Budget    *ConfigValue    `json:"budget"`
	Disks     *ConfigValue    `json:"disks"`
	Target    *ConfigValue    `json:"target"`
	Wipe      *ConfigValue    `json:"wipe"`
	Base      *ConfigValue    `json:"base"`
	Mode      *ConfigValue    `json:"mode"`
	Config    *ConfigValue    `json:"config"`
	Reference *ConfigValue    `json:"reference"`
	Previous  *ConfigValue    `json:"previous"`
	Changes   *ConfigValue    `json:"changes"`
	Paths     []string        `json:"paths"`
	Rows      []InventoryRow  `json:"rows"`
	Spool     string          `json:"spool"`
	Names     []string        `json:"names"`
	IOHooks   map[string]bool `json:"io_hooks"`
}

type InventoryRow struct {
	Parts      []*ConfigValue      `json:"parts"`
	Capacities []InventoryCapacity `json:"capacities"`
}

type InventoryCapacity struct {
	Digit   bool   `json:"digit"`
	Integer string `json:"integer"`
	Error   string `json:"error"`
}

type tariValueResult struct {
	Value       *ConfigValue `json:"value,omitempty"`
	NeedDefault bool         `json:"need_default,omitempty"`
}

type explicitValueResult struct {
	Value   *ConfigValue `json:"value"`
	Same    bool         `json:"same"`
	Aliases [][]string   `json:"aliases"`
	Paths   [][]string   `json:"paths"`
}

func tariValue(request ValuesRequest) (tariValueResult, error) {
	if request.Disks.PythonTruth() {
		if request.Disks.Kind != "list" {
			return tariValueResult{}, configTypeError{"disks must be a list"}
		}
		for _, disk := range request.Disks.Items {
			if disk.Kind != "dict" {
				return tariValueResult{}, configTypeError{"disk entry must be an object"}
			}
			name, ok := disk.Field("name")
			if !ok {
				return tariValueResult{}, configKeyError{"name"}
			}
			if !configEqual(name, request.Target, false) {
				continue
			}
			state, _ := disk.Field("state")
			if configStringEqual(state, "pithead-with-data") && configStringEqual(request.Wipe, "data") {
				return tariValueResult{Value: configString("local")}, nil
			}
			return tariValueResult{NeedDefault: true}, nil
		}
		return tariValueResult{NeedDefault: true}, nil
	}
	if request.Budget == nil || request.Budget.Kind != "dict" {
		return tariValueResult{}, configTypeError{"budget must be an object"}
	}
	held, _ := request.Budget.Field("tari_chain_held")
	if strictConfigEqual(held, &ConfigValue{Kind: "bool", Bool: true}) {
		return tariValueResult{Value: configString("local")}, nil
	}
	return tariValueResult{NeedDefault: true}, nil
}

func answersValue(base, mode *ConfigValue) *ConfigValue {
	return DeepMerge(base, &ConfigValue{Kind: "dict", Fields: []ConfigField{{
		Key:   "tari",
		Value: &ConfigValue{Kind: "dict", Fields: []ConfigField{{Key: "mode", Value: mode.Clone()}}},
	}}})
}

func explicitValue(config, reference *ConfigValue, runtimePaths []string) (explicitValueResult, error) {
	result := explicitValueResult{Aliases: [][]string{}, Paths: [][]string{}}
	if !reference.PythonTruth() {
		result.Value = config
		result.Same = true
	} else {
		result.Value = StripDefaults(config, reference)
		result.Aliases = retainedValuePaths(config, reference, nil)
	}
	for _, path := range runtimePaths {
		parts := strings.Split(path, ".")
		if len(parts) != 2 {
			if len(parts) < 2 {
				return explicitValueResult{}, ValidationError{fmt.Sprintf("not enough values to unpack (expected 2, got %d)", len(parts))}
			}
			return explicitValueResult{}, ValidationError{"too many values to unpack (expected 2)"}
		}
		block, ok := config.Field(parts[0])
		if ok && block.Kind == "dict" {
			if _, present := block.Field(parts[1]); present {
				result.Paths = append(result.Paths, parts)
			}
		}
	}
	return result, nil
}

func retainedValuePaths(config, reference *ConfigValue, prefix []string) [][]string {
	paths := [][]string{}
	if config == nil || config.Kind != "dict" {
		return paths
	}
	for _, field := range config.Fields {
		if strings.HasPrefix(field.Key, "_") {
			continue
		}
		path := append(append([]string{}, prefix...), field.Key)
		defaultValue, known := reference.Field(field.Key)
		if field.Value.Kind == "dict" && known && defaultValue.Kind == "dict" {
			paths = append(paths, retainedValuePaths(field.Value, defaultValue, path)...)
		} else if !known || !field.Value.Equal(defaultValue) {
			paths = append(paths, path)
		}
	}
	return paths
}

func rememberValue(previous, changes *ConfigValue) (*ConfigValue, error) {
	items := []*ConfigValue{}
	if previous != nil && previous.Kind == "list" {
		valid := true
		for _, item := range previous.Items {
			if item.Kind != "str" {
				valid = false
				break
			}
		}
		if valid {
			items = append(items, previous.Items...)
		}
	}
	if changes == nil || changes.Kind != "list" {
		return nil, configTypeError{"changes must be a list"}
	}
	items = append(items, changes.Items...)
	unique := make([]*ConfigValue, 0, len(items))
	for _, item := range items {
		if err := requireHashable(item); err != nil {
			return nil, err
		}
		if !containsValue(unique, item) {
			unique = append(unique, item.Clone())
		}
	}
	return &ConfigValue{Kind: "list", Items: unique}, nil
}

func inventoryValue(rows []InventoryRow) (*ConfigValue, error) {
	items := []*ConfigValue{}
	keys := []string{"name", "size", "model", "serial", "state"}
	capacityKeys := []string{"data_bytes", "data_available_bytes"}
	for _, row := range rows {
		if len(row.Parts) < len(keys) {
			continue
		}
		disk := configDict()
		for index, key := range keys {
			if row.Parts[index] == nil {
				return nil, configTypeError{"inventory field must be a string"}
			}
			disk.Set(key, row.Parts[index].Clone())
		}
		for index, capacity := range row.Capacities {
			if index >= len(capacityKeys) || !capacity.Digit {
				continue
			}
			if capacity.Error != "" {
				return nil, ValidationError{capacity.Error}
			}
			value := &ConfigValue{Kind: "int", Text: capacity.Integer}
			if !validInteger(value.Text) {
				return nil, ValidationError{fmt.Sprintf("invalid inventory integer %q", value.Text)}
			}
			disk.Set(capacityKeys[index], value)
		}
		items = append(items, disk)
	}
	return &ConfigValue{Kind: "list", Items: items}, nil
}

func removeSpoolValues(spool string, names []string, transactionIO transactionIO) error {
	for _, name := range names {
		path := transactionJoin(spool, name)
		if _, err := os.Stat(path); err != nil {
			continue
		}
		if err := transactionIO.Unlink(path); err != nil {
			if callback, ok := err.(callbackError); ok && callback.errno != 0 {
				callback.message = strings.TrimPrefix(callback.message, fmt.Sprintf("[Errno %d] ", callback.errno))
				return callback
			}
			return err
		}
	}
	return nil
}

func configString(value string) *ConfigValue {
	return &ConfigValue{Kind: "str", Text: value}
}

func configStringEqual(value *ConfigValue, expected string) bool {
	return value != nil && value.Kind == "str" && value.Text == expected
}
