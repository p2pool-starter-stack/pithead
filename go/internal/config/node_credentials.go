package config

import (
	"encoding/json"
	"strings"
)

const placeholderNodeUser = "create_a_username_for_node"
const placeholderNodePass = "create_a_password_for_node"

type NodeCredentials struct {
	User         string
	Pass         string
	GenerateUser bool
	GeneratePass bool
}

func ParseNodeCredentials(raw []byte, mode, user string) (NodeCredentials, error) {
	document, err := ParseDocument(raw)
	if err != nil || document == nil || duplicateError(document.root, "") != "" {
		return NodeCredentials{}, ErrUnsupportedValidation
	}
	credentials := NodeCredentials{User: user}
	credentials.Pass, err = accessScalar(document.root, "monero.node_password", "")
	if err != nil {
		return NodeCredentials{}, err
	}
	if mode == "local" {
		credentials.GenerateUser = credentials.User == "" || credentials.User == placeholderNodeUser
		credentials.GeneratePass = credentials.Pass == "" || credentials.Pass == placeholderNodePass
	}
	return credentials, nil
}

func accessScalar(root node, path, fallback string) (string, error) {
	value, err := getStringPath(root, path)
	if err != nil || value.object != nil || value.array != nil {
		return "", ErrUnsupportedValidation
	}
	if isNull(value) || value.value == false {
		return fallback, nil
	}
	switch typed := value.value.(type) {
	case string:
		if strings.ContainsRune(typed, 0) {
			return "", ErrUnsupportedValidation
		}
		return strings.TrimRight(typed, "\n"), nil
	case bool:
	case json.Number:
		if !validJQInteger(typed.String()) {
			return "", ErrUnsupportedValidation
		}
	default:
		return "", ErrUnsupportedValidation
	}
	rendered, err := rawJQ(value)
	if err != nil {
		return "", ErrUnsupportedValidation
	}
	return strings.TrimRight(string(rendered), "\n"), nil
}
