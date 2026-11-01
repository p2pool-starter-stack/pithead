package config

import (
	"encoding/json"
	"errors"
	"strings"
)

var ErrUnsupportedMigration = errors.New("unsupported config migration")

type LegacyWorkersPlan struct {
	Conflict  string
	Need      bool
	Populated bool
}

type TelegramControlPlan struct {
	Need        bool
	WarnEnabled bool
}

func PlanLegacyWorkers(raw, keysRaw, defaultsRaw []byte) (LegacyWorkersPlan, error) {
	root, keys, defaults, err := parseLegacyMigration(raw, keysRaw, defaultsRaw)
	if err != nil {
		return LegacyWorkersPlan{}, err
	}
	dashboard, err := migrationObject(root, "dashboard")
	if err != nil {
		return LegacyWorkersPlan{}, err
	}
	workers, err := migrationObject(root, "workers")
	if err != nil {
		return LegacyWorkersPlan{}, err
	}
	oldList, err := migrationFallback(dashboard, "workers", node{array: []node{}})
	if err != nil {
		return LegacyWorkersPlan{}, err
	}
	newList, err := migrationFallback(workers, "list", node{array: []node{}})
	if err != nil {
		return LegacyWorkersPlan{}, err
	}
	conflicts := make([]string, 0, len(keys)+1)
	if !nodeEqual(oldList, node{array: []node{}}) && !nodeEqual(newList, node{array: []node{}}) && !nodeEqual(oldList, newList) {
		conflicts = append(conflicts, "workers.list[] and dashboard.workers[]")
	}
	oldXVB, err := migrationObject(root, "xmrig_proxy")
	if err != nil {
		return LegacyWorkersPlan{}, err
	}
	newXVB, err := migrationObject(root, "xvb")
	if err != nil {
		return LegacyWorkersPlan{}, err
	}
	populated := !nodeEqual(oldList, node{array: []node{}})
	for _, key := range keys {
		oldValue, oldSet := objectValue(oldXVB, key)
		newValue, newSet := objectValue(newXVB, key)
		defaultValue, _ := objectValue(defaults, key)
		if oldSet && newSet && !nodeEqual(oldValue, newValue) && !nodeEqual(oldValue, defaultValue) {
			conflicts = append(conflicts, "xvb."+key+" and xmrig_proxy."+key)
		}
		if oldSet && !newSet {
			populated = true
		}
	}
	_, oldBlock := objectValue(root, "xmrig_proxy")
	_, oldWorkers := objectValue(dashboard, "workers")
	return LegacyWorkersPlan{
		Conflict:  strings.Join(conflicts, "; "),
		Need:      oldBlock || oldWorkers,
		Populated: populated,
	}, nil
}

func MigrateLegacyWorkers(raw, keysRaw, defaultsRaw []byte) ([]byte, error) {
	root, keys, _, err := parseLegacyMigration(raw, keysRaw, defaultsRaw)
	if err != nil {
		return nil, err
	}
	dashboard, err := migrationObject(root, "dashboard")
	if err != nil {
		return nil, err
	}
	oldList, err := migrationFallback(dashboard, "workers", node{array: []node{}})
	if err != nil {
		return nil, err
	}
	if !nodeEqual(oldList, node{array: []node{}}) {
		workers, objectErr := migrationObject(root, "workers")
		if objectErr != nil {
			return nil, objectErr
		}
		setObjectMember(&workers, "list", objectMember(dashboard, "workers"))
		setObjectMember(&root, "workers", workers)
	}
	if dashboardValue, exists := objectValue(root, "dashboard"); exists && dashboardValue.object != nil {
		deleteObjectMember(&dashboardValue, "workers")
		setObjectMember(&root, "dashboard", dashboardValue)
	}
	oldXVB, err := migrationObject(root, "xmrig_proxy")
	if err != nil {
		return nil, err
	}
	newXVB, err := migrationObject(root, "xvb")
	if err != nil {
		return nil, err
	}
	for _, key := range keys {
		oldValue, oldSet := objectValue(oldXVB, key)
		_, newSet := objectValue(newXVB, key)
		if oldSet && !newSet {
			setObjectMember(&newXVB, key, oldValue)
			setObjectMember(&root, "xvb", newXVB)
		}
	}
	deleteObjectMember(&root, "xmrig_proxy")
	return migrationJSON(root)
}

func PlanTelegramControl(raw []byte) (TelegramControlPlan, error) {
	root, err := parseMigrationRoot(raw)
	if err != nil {
		return TelegramControlPlan{}, err
	}
	telegram, err := migrationObject(root, "telegram")
	if err != nil {
		return TelegramControlPlan{}, err
	}
	control, need := objectValue(telegram, "control")
	warn := false
	if need && control.object != nil {
		if enabled, ok := objectValue(control, "enabled"); ok {
			if value, stringValue := enabled.value.(string); stringValue {
				if strings.ContainsRune(value, 0) {
					return TelegramControlPlan{}, ErrUnsupportedMigration
				}
				warn = strings.TrimRight(value, "\n") == "true"
			} else {
				warn = enabled.value == true
			}
		}
	}
	return TelegramControlPlan{Need: need, WarnEnabled: warn}, nil
}

func MigrateTelegramControl(raw []byte) ([]byte, error) {
	root, err := parseMigrationRoot(raw)
	if err != nil {
		return nil, err
	}
	if telegram, exists := objectValue(root, "telegram"); exists && telegram.object != nil {
		deleteObjectMember(&telegram, "control")
		setObjectMember(&root, "telegram", telegram)
	}
	return migrationJSON(root)
}

func parseLegacyMigration(raw, keysRaw, defaultsRaw []byte) (node, []string, node, error) {
	root, err := parseMigrationRoot(raw)
	if err != nil {
		return node{}, nil, node{}, err
	}
	keysDocument, keysErr := ParseDocument(keysRaw)
	defaultsDocument, defaultsErr := ParseDocument(defaultsRaw)
	if keysErr != nil || defaultsErr != nil || keysDocument == nil || defaultsDocument == nil || keysDocument.root.array == nil || defaultsDocument.root.object == nil || duplicateError(defaultsDocument.root, "") != "" {
		return node{}, nil, node{}, ErrUnsupportedMigration
	}
	keys := make([]string, 0, len(keysDocument.root.array))
	for _, item := range keysDocument.root.array {
		key, ok := item.value.(string)
		if !ok {
			return node{}, nil, node{}, ErrUnsupportedMigration
		}
		keys = append(keys, key)
	}
	return root, keys, defaultsDocument.root, nil
}

func parseMigrationRoot(raw []byte) (node, error) {
	document, err := ParseDocument(raw)
	if err != nil || document == nil || document.root.object == nil || duplicateError(document.root, "") != "" {
		return node{}, ErrUnsupportedMigration
	}
	if _, err := prettyJQ(document.root); err != nil {
		return node{}, ErrUnsupportedMigration
	}
	return cloneNode(document.root), nil
}

func migrationObject(root node, key string) (node, error) {
	value, exists := objectValue(root, key)
	if !exists || isNull(value) || value.value == false {
		return node{object: []member{}}, nil
	}
	if value.object == nil {
		return node{}, ErrUnsupportedMigration
	}
	return cloneNode(value), nil
}

func migrationFallback(root node, key string, fallback node) (node, error) {
	value, exists := objectValue(root, key)
	if !exists || isNull(value) || value.value == false {
		return cloneNode(fallback), nil
	}
	if value.object == nil && value.array == nil {
		switch value.value.(type) {
		case string, bool, json.Number:
		default:
			return node{}, ErrUnsupportedMigration
		}
	}
	return cloneNode(value), nil
}
