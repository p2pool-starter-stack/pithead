package wizard

var legacyAliases = []string{"enabled", "url", "donor_id"}

func legacyConflicts(cfg, defaults *ConfigValue) []string {
	var conflicts []string
	dashboard := dictField(cfg, "dashboard")
	workers := dictField(cfg, "workers")
	oldWorkers := fieldOrEmptyList(dashboard, "workers")
	newWorkers := fieldOrEmptyList(workers, "list")
	if legacyHasData(oldWorkers) && legacyHasData(newWorkers) && !oldWorkers.Equal(newWorkers) {
		conflicts = append(conflicts, "workers.list and dashboard.workers")
	}
	oldXVB := dictField(cfg, "xmrig_proxy")
	newXVB := dictField(cfg, "xvb")
	oldRaw, oldPresent := cfg.Field("xmrig_proxy")
	newRaw, newPresent := cfg.Field("xvb")
	if oldPresent && oldRaw.Kind != "dict" && newPresent && !oldRaw.Equal(newRaw) {
		conflicts = append(conflicts, "xvb and xmrig_proxy")
	}
	for _, key := range legacyAliases {
		oldValue, oldOK := oldXVB.Field(key)
		newValue, newOK := newXVB.Field(key)
		defaultValue, defaultOK := defaults.Field(key)
		if oldOK && newOK && !oldValue.Equal(newValue) && !(defaultOK && strictConfigEqual(oldValue, defaultValue)) {
			conflicts = append(conflicts, "xvb."+key+" and xmrig_proxy."+key)
		}
	}
	return conflicts
}

func migrateLegacy(cfg *ConfigValue, changes *[]string) {
	oldXVB, hadOldXVB := cfg.Delete("xmrig_proxy")
	if hadOldXVB && oldXVB.Kind == "dict" {
		newXVB, newPresent := cfg.Field("xvb")
		canCopy := !newPresent || newXVB.Kind == "null" || newXVB.Kind == "dict"
		if !newPresent || newXVB.Kind == "null" {
			newXVB = configDict()
			cfg.Set("xvb", newXVB)
		}
		for _, field := range oldXVB.Fields {
			oldPath := "xmrig_proxy." + field.Key
			newPath := "xvb." + field.Key
			_, exists := newXVB.Field(field.Key)
			if containsString(legacyAliases, field.Key) && canCopy && !exists {
				newXVB.Set(field.Key, field.Value)
				addChange(changes, oldPath, newPath)
			} else {
				addChange(changes, oldPath, "")
			}
		}
	} else if hadOldXVB && oldXVB.Kind != "null" && !(oldXVB.Kind == "bool" && !oldXVB.Bool) {
		if _, exists := cfg.Field("xvb"); !exists {
			cfg.Set("xvb", oldXVB)
			addChange(changes, "xmrig_proxy", "xvb")
		} else {
			addChange(changes, "xmrig_proxy", "")
		}
	}

	dashboard := dictField(cfg, "dashboard")
	oldWorkers, hadOldWorkers := dashboard.Delete("workers")
	if !hadOldWorkers {
		return
	}
	workers, workersPresent := cfg.Field("workers")
	canCopy := !workersPresent || workers.Kind == "null" || workers.Kind == "dict"
	if !workersPresent || workers.Kind == "null" {
		workers = configDict()
		cfg.Set("workers", workers)
	}
	current, currentPresent := workers.Field("list")
	if !currentPresent {
		current = configNull()
	}
	if canCopy && legacyHasData(oldWorkers) && !legacyHasData(current) {
		workers.Set("list", oldWorkers)
		addChange(changes, "dashboard.workers", "workers.list")
	} else {
		addChange(changes, "dashboard.workers", "")
	}
}

func legacyHasData(value *ConfigValue) bool {
	if value == nil || value.Kind == "null" || value.Kind == "bool" && !value.Bool {
		return false
	}
	return value.Kind != "list" || len(value.Items) != 0
}

func dictField(value *ConfigValue, key string) *ConfigValue {
	field, ok := value.Field(key)
	if !ok || field.Kind != "dict" {
		return configDict()
	}
	return field
}

func fieldOrEmptyList(value *ConfigValue, key string) *ConfigValue {
	field, ok := value.Field(key)
	if !ok {
		return &ConfigValue{Kind: "list"}
	}
	return field
}

func configNull() *ConfigValue { return &ConfigValue{Kind: "null"} }

func containsString(values []string, wanted string) bool {
	for _, value := range values {
		if value == wanted {
			return true
		}
	}
	return false
}
