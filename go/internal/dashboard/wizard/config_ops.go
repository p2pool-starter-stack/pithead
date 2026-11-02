package wizard

import (
	"fmt"
	"regexp"
	"strings"
)

var legacyMachineName = regexp.MustCompile(`^[a-zA-Z0-9._:-]{0,253}$`)
var machineName = regexp.MustCompile(`^[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$`)

type configKeyError struct{ key string }

func (e configKeyError) Error() string { return fmt.Sprintf("'%s'", e.key) }

type configTypeError struct{ message string }

func (e configTypeError) Error() string { return e.message }

func DeepMerge(base, over *ConfigValue) *ConfigValue {
	out := base.Clone()
	if over == nil || over.Kind == "null" {
		return out
	}
	for _, field := range over.Fields {
		current, ok := out.Field(field.Key)
		if ok && current.Kind == "dict" && field.Value.Kind == "dict" {
			out.Set(field.Key, DeepMerge(current, field.Value))
		} else {
			out.Set(field.Key, field.Value.Clone())
		}
	}
	return out
}

func StripDefaults(config, reference *ConfigValue) *ConfigValue {
	out := configDict()
	if config == nil || config.Kind == "null" {
		return out
	}
	for _, field := range config.Fields {
		if strings.HasPrefix(field.Key, "_") {
			continue
		}
		defaultValue, known := reference.Field(field.Key)
		if field.Value.Kind == "dict" && known && defaultValue.Kind == "dict" {
			sub := StripDefaults(field.Value, defaultValue)
			if len(sub.Fields) != 0 {
				out.Set(field.Key, sub)
			}
		} else if !known || !field.Value.Equal(defaultValue) {
			out.Set(field.Key, field.Value.Clone())
		}
	}
	return out
}

func ValidateMachineName(config, previous, defaultHost *ConfigValue) error {
	dashboard, ok := config.Field("dashboard")
	if !ok {
		dashboard = configDict()
	}
	if dashboard.Kind != "dict" {
		return ValidationError{"dashboard must be an object"}
	}
	host, ok := dashboard.Field("host")
	if !ok {
		host = defaultHost
	}
	if host != nil && host.Kind == "str" && host.Text == "auto" {
		return nil
	}
	if saved, exists := previous.Field("dashboard"); exists && saved.Kind == "dict" {
		if savedHost, present := saved.Field("host"); present && host != nil && host.Equal(savedHost) && host.Kind == "str" && legacyMachineName.MatchString(host.Text) {
			return nil
		}
	}
	if host == nil || host.Kind != "str" || !machineName.MatchString(host.Text) {
		return ValidationError{"Name this machine must be 1–63 letters, digits or hyphens, starting and ending with a letter or digit"}
	}
	return nil
}

func RecoveryState(changes, attempt, disks, mode *ConfigValue) ([]string, *ConfigValue, string, error) {
	remembered, err := rememberedChanges(changes)
	if err != nil {
		return nil, nil, "", err
	}
	offered, err := offeredDisks(disks)
	if err != nil {
		return nil, nil, "", err
	}
	if attempt == nil || attempt.Kind != "dict" {
		return nil, nil, "", configTypeError{"install attempt must be an object"}
	}
	selected := configDict()
	disk, hasDisk := attempt.Field("disk")
	wipe, hasWipe := attempt.Field("wipe")
	if hasDisk {
		if err := requireHashable(disk); err != nil {
			return nil, nil, "", err
		}
	}
	if hasDisk && hasWipe && containsValue(offered, disk) && wipe.Kind == "str" && (wipe.Text == "keep" || wipe.Text == "data" || wipe.Text == "all") {
		selected.Set("disk", disk.Clone())
		selected.Set("wipe", wipe.Clone())
	}
	authMode := "auto"
	if mode.PythonTruth() && mode.Kind == "str" && (mode.Text == "auto" || mode.Text == "set" || mode.Text == "none") {
		authMode = mode.Text
	}
	return remembered, selected, authMode, nil
}

func rememberedChanges(value *ConfigValue) ([]string, error) {
	if value == nil || value.Kind != "dict" {
		return nil, configTypeError{"config changes must be an object"}
	}
	items, ok := value.Field("changes")
	if !ok || items.Kind != "list" {
		return []string{}, nil
	}
	remembered := make([]string, 0, len(items.Items))
	for _, item := range items.Items {
		if item.Kind != "str" {
			return []string{}, nil
		}
		remembered = append(remembered, item.Text)
	}
	return remembered, nil
}

func offeredDisks(disks *ConfigValue) ([]*ConfigValue, error) {
	if disks == nil || disks.Kind != "list" {
		return nil, configTypeError{"disks must be a list"}
	}
	offered := make([]*ConfigValue, 0, len(disks.Items))
	for _, disk := range disks.Items {
		if disk.Kind != "dict" {
			return nil, configTypeError{"disk entry must be an object"}
		}
		name, ok := disk.Field("name")
		if !ok {
			return nil, configKeyError{"name"}
		}
		if err := requireHashable(name); err != nil {
			return nil, err
		}
		offered = append(offered, name)
	}
	return offered, nil
}

func requireHashable(value *ConfigValue) error {
	if value != nil && (value.Kind == "list" || value.Kind == "dict") {
		return configTypeError{fmt.Sprintf("unhashable type: '%s'", map[string]string{"list": "list", "dict": "dict"}[value.Kind])}
	}
	return nil
}

func containsValue(values []*ConfigValue, target *ConfigValue) bool {
	for _, value := range values {
		if configEqual(value, target, true) {
			return true
		}
	}
	return false
}

func configDict() *ConfigValue { return &ConfigValue{Kind: "dict"} }
