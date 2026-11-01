package config

import (
	"encoding/json"
	"errors"
	"strconv"
)

var ErrUnsupportedMaskedConfig = errors.New("unsupported masked config")

func MaskConfig(raw, pathsRaw []byte) ([]byte, error) {
	root, err := parsePersistenceRoot(raw)
	if err != nil {
		return nil, ErrUnsupportedMaskedConfig
	}
	paths, err := parseMaskedPaths(pathsRaw)
	if err != nil {
		return nil, err
	}
	for _, path := range paths {
		target, ok := maskedPath(&root, path)
		if ok && maskedValueSet(*target) {
			*target = maskedSentinel()
		}
	}
	if err := maskWorkerTokens(&root, "workers", "list"); err != nil {
		return nil, err
	}
	if err := maskWorkerTokens(&root, "dashboard", "workers"); err != nil {
		return nil, err
	}
	maskWebhooks(&root)
	rendered, err := prettyJQ(root)
	if err != nil {
		return nil, ErrUnsupportedMaskedConfig
	}
	return rendered, nil
}

func parseMaskedPaths(raw []byte) ([][]string, error) {
	document, err := ParseDocument(raw)
	if err != nil || document == nil || document.root.array == nil || duplicateError(document.root, "") != "" {
		return nil, ErrUnsupportedMaskedConfig
	}
	paths := make([][]string, len(document.root.array))
	for index, entry := range document.root.array {
		if entry.array == nil || len(entry.array) == 0 {
			return nil, ErrUnsupportedMaskedConfig
		}
		paths[index] = make([]string, len(entry.array))
		for partIndex, part := range entry.array {
			value, ok := part.value.(string)
			if !ok {
				return nil, ErrUnsupportedMaskedConfig
			}
			paths[index][partIndex] = value
		}
	}
	return paths, nil
}

func maskedPath(root *node, path []string) (*node, bool) {
	current := root
	for _, part := range path {
		if isNull(*current) || current.object == nil {
			return nil, false
		}
		found := false
		for index := range current.object {
			if current.object[index].key == part {
				current = &current.object[index].value
				found = true
				break
			}
		}
		if !found {
			return nil, false
		}
	}
	return current, true
}

func maskedValueSet(value node) bool {
	if isNull(value) || value.value == false {
		return false
	}
	text, stringValue := value.value.(string)
	return !stringValue || text != ""
}

func maskedSentinel() node {
	return node{object: []member{{key: "__secret__", value: node{value: true}}}}
}

func maskWorkerTokens(root *node, parentKey, listKey string) error {
	parent, ok := objectValue(*root, parentKey)
	if !ok || parent.object == nil {
		return nil
	}
	list, ok := objectValue(parent, listKey)
	if !ok || list.array == nil {
		return nil
	}
	for index := range list.array {
		entry := &list.array[index]
		if isNull(*entry) {
			continue
		}
		if entry.object == nil {
			return ErrUnsupportedMaskedConfig
		}
		for _, key := range []string{"token", "api_token"} {
			value, exists := objectValue(*entry, key)
			if exists && maskedValueSet(value) {
				setObjectMember(entry, key, maskedSentinel())
			}
		}
	}
	setObjectMember(&parent, listKey, list)
	setObjectMember(root, parentKey, parent)
	return nil
}

func maskWebhooks(root *node) {
	notifications, ok := objectValue(*root, "notifications")
	if !ok || notifications.object == nil {
		return
	}
	webhooks, ok := objectValue(notifications, "webhooks")
	if !ok || webhooks.array == nil {
		return
	}
	for index, value := range webhooks.array {
		if maskedValueSet(value) {
			webhooks.array[index] = node{object: []member{
				{key: "__secret__", value: node{value: true}},
				{key: "slot", value: node{value: json.Number(strconv.Itoa(index))}},
			}}
		}
	}
	setObjectMember(&notifications, "webhooks", webhooks)
	setObjectMember(root, "notifications", notifications)
}
