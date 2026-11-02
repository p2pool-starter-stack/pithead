package wizard

import (
	"sort"
	"strings"
)

func auditDiff(arguments *ConfigValue) (*ConfigValue, error) {
	old, err := auditField(arguments, "old")
	if err != nil {
		return nil, err
	}
	newValue, err := auditField(arguments, "new")
	if err != nil {
		return nil, err
	}
	oldFlat := make(map[string]*ConfigValue)
	newFlat := make(map[string]*ConfigValue)
	auditFlatten(old, "", oldFlat)
	auditFlatten(newValue, "", newFlat)
	changed := make(map[string]bool)
	for path, oldValue := range oldFlat {
		newLeaf, ok := newFlat[path]
		if !ok || !oldValue.Equal(newLeaf) {
			changed[path] = true
		}
	}
	for path := range newFlat {
		if _, ok := oldFlat[path]; !ok {
			changed[path] = true
		}
	}
	paths := make([]string, 0, len(changed))
	for path := range changed {
		if strings.SplitN(path, ".", 2)[0] != "config_version" {
			paths = append(paths, path)
		}
	}
	sort.Strings(paths)
	return configStrings(paths), nil
}

func auditUnexplained(arguments *ConfigValue) (*ConfigValue, error) {
	changedValue, err := auditField(arguments, "changed")
	if err != nil {
		return nil, err
	}
	explainedValue, err := auditField(arguments, "explained")
	if err != nil {
		return nil, err
	}
	changed, err := editorStringList(changedValue, "changed", false)
	if err != nil {
		return nil, err
	}
	explained, err := editorStringList(explainedValue, "explained", false)
	if err != nil {
		return nil, err
	}
	result := make([]string, 0, len(changed))
	for _, path := range changed {
		covered := false
		for _, prefix := range explained {
			if path == prefix || strings.HasPrefix(path, prefix+".") {
				covered = true
				break
			}
		}
		if !covered {
			result = append(result, path)
		}
	}
	return configStrings(result), nil
}

func auditFlatten(value *ConfigValue, prefix string, flattened map[string]*ConfigValue) {
	if value == nil || value.Kind != "dict" {
		return
	}
	for _, field := range value.Fields {
		path := field.Key
		if prefix != "" {
			path = prefix + "." + field.Key
		}
		if field.Value.Kind == "dict" && !auditSecretSentinel(field.Value) {
			auditFlatten(field.Value, path, flattened)
		} else {
			flattened[path] = field.Value
		}
	}
}

func auditSecretSentinel(value *ConfigValue) bool {
	if value == nil || value.Kind != "dict" || len(value.Fields) != 1 || value.Fields[0].Key != "__secret__" {
		return false
	}
	return value.Fields[0].Value.Equal(auditTrue)
}

func auditField(arguments *ConfigValue, name string) (*ConfigValue, error) {
	if arguments == nil || arguments.Kind != "dict" {
		return nil, configTypeError{"audit arguments must be an object"}
	}
	value, ok := arguments.Field(name)
	if !ok {
		return nil, configKeyError{name}
	}
	return value, nil
}

var auditTrue = &ConfigValue{Kind: "bool", Bool: true}
