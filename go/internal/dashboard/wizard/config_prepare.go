package wizard

import "strings"

var workerFields = map[string]struct{}{
	"name": {}, "host": {}, "port": {}, "control_port": {}, "token": {}, "watts": {},
}

func PrepareConfig(cfg, ref, legacyDefaults *ConfigValue, reject bool) (*ConfigValue, []string, error) {
	if cfg == nil || cfg.Kind != "dict" {
		return nil, nil, ValidationError{"config must be an object"}
	}
	if ref == nil || ref.Kind != "dict" {
		return nil, nil, ValidationError{"reference must be an object"}
	}
	if legacyDefaults == nil || legacyDefaults.Kind != "dict" {
		return nil, nil, ValidationError{"legacy defaults must be an object"}
	}
	prepared := cfg.Clone()
	prepared.Delete("config_version")
	conflicts := legacyConflicts(prepared, legacyDefaults)
	if reject && len(conflicts) != 0 {
		return nil, nil, ValidationError{"removed 1.x keys differ from their replacements (" + strings.Join(conflicts, "; ") + ")"}
	}
	var changes []string
	migrateLegacy(prepared, &changes)
	if ref.PythonTruth() {
		prepared = knownOnly(prepared, ref, &changes, "")
	}
	return prepared, uniqueStrings(changes), nil
}

func knownOnly(cfg, ref *ConfigValue, changes *[]string, prefix string) *ConfigValue {
	known := configDict()
	for _, field := range cfg.Fields {
		path := field.Key
		if prefix != "" {
			path = prefix + "." + field.Key
		}
		refValue, exists := ref.Field(field.Key)
		if !exists {
			addChange(changes, path, "")
			continue
		}
		if path == "workers.list" && field.Value.Kind == "list" {
			items := make([]*ConfigValue, 0, len(field.Value.Items))
			for _, item := range field.Value.Items {
				if item.Kind != "dict" {
					items = append(items, item.Clone())
					continue
				}
				clean := configDict()
				for _, workerField := range item.Fields {
					if _, ok := workerFields[workerField.Key]; ok {
						clean.Set(workerField.Key, workerField.Value.Clone())
					} else {
						addChange(changes, path+"[]."+workerField.Key, "")
					}
				}
				items = append(items, clean)
			}
			known.Set(field.Key, &ConfigValue{Kind: "list", Items: items})
		} else if field.Value.Kind == "dict" && refValue.Kind == "dict" {
			known.Set(field.Key, knownOnly(field.Value, refValue, changes, path))
		} else {
			known.Set(field.Key, field.Value.Clone())
		}
	}
	return known
}

func addChange(changes *[]string, path, replacement string) {
	if replacement == "" {
		*changes = append(*changes, path+" removed")
	} else {
		*changes = append(*changes, path+" → "+replacement)
	}
}

func uniqueStrings(values []string) []string {
	seen := make(map[string]struct{}, len(values))
	unique := make([]string, 0, len(values))
	for _, value := range values {
		if _, ok := seen[value]; ok {
			continue
		}
		seen[value] = struct{}{}
		unique = append(unique, value)
	}
	return unique
}
