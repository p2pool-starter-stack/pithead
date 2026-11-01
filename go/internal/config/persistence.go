package config

import "errors"

var ErrUnsupportedPersistence = errors.New("unsupported config persistence")

func PersistNodeCredentials(raw []byte, username, password string) ([]byte, error) {
	root, err := parsePersistenceRoot(raw)
	if err != nil {
		return nil, err
	}
	monero, exists := objectValue(root, "monero")
	if !exists || isNull(monero) {
		monero = node{object: []member{}}
	} else if monero.object == nil {
		return nil, ErrUnsupportedPersistence
	}
	setObjectMember(&monero, "node_username", node{value: username})
	setObjectMember(&monero, "node_password", node{value: password})
	setObjectMember(&root, "monero", monero)
	return persistenceJSON(root)
}

func ApplyApplianceDefaults(raw, defaultsRaw []byte) ([]byte, error) {
	root, err := parsePersistenceRoot(raw)
	if err != nil {
		return nil, err
	}
	defaults, err := parsePersistenceRoot(defaultsRaw)
	if err != nil {
		return nil, err
	}
	autoHeal, err := getStringPath(root, "tor.auto_heal")
	if err != nil {
		return nil, ErrUnsupportedPersistence
	}
	if isNull(autoHeal) {
		value, valueErr := getStringPath(defaults, "tor.auto_heal")
		if valueErr != nil || setStringPath(&root, "tor.auto_heal", value) != nil {
			return nil, ErrUnsupportedPersistence
		}
	}
	controlEnabled, err := getStringPath(root, "dashboard.control.enabled")
	if err != nil {
		return nil, ErrUnsupportedPersistence
	}
	password, err := getStringPath(root, "dashboard.auth.password")
	if err != nil {
		return nil, ErrUnsupportedPersistence
	}
	if isNull(controlEnabled) && persistenceNonempty(password) {
		value, valueErr := getStringPath(defaults, "dashboard.control.enabled")
		if valueErr != nil || setStringPath(&root, "dashboard.control.enabled", value) != nil {
			return nil, ErrUnsupportedPersistence
		}
	}
	return persistenceJSON(root)
}

func parsePersistenceRoot(raw []byte) (node, error) {
	document, err := ParseDocument(raw)
	if err != nil || document == nil || document.root.object == nil || duplicateError(document.root, "") != "" {
		return node{}, ErrUnsupportedPersistence
	}
	if _, err := prettyJQ(document.root); err != nil {
		return node{}, ErrUnsupportedPersistence
	}
	return cloneNode(document.root), nil
}

func persistenceNonempty(value node) bool {
	if isNull(value) || value.value == false {
		return false
	}
	if text, ok := value.value.(string); ok {
		return text != ""
	}
	return true
}

func persistenceJSON(root node) ([]byte, error) {
	rendered, err := prettyJQ(root)
	if err != nil {
		return nil, ErrUnsupportedPersistence
	}
	return rendered, nil
}
