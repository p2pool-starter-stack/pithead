package config

import (
	"errors"
	"strings"
)

var ErrUnsupportedDefaults = errors.New("unsupported config defaults")

type Defaults struct {
	table node
}

func NewDefaults(raw []byte) (*Defaults, error) {
	document, err := ParseDocument(raw)
	if err != nil || document == nil || duplicateError(document.root, "") != "" || !validDefaultsTable(document.root) {
		return nil, ErrUnsupportedDefaults
	}
	if _, err = prettyJQ(document.root); err != nil {
		return nil, ErrUnsupportedDefaults
	}
	return &Defaults{table: cloneNode(document.root)}, nil
}

func (defaults *Defaults) Render(mode, platform string) ([]byte, error) {
	root, err := defaults.renderNode(mode, platform)
	if err != nil {
		return nil, err
	}
	return prettyJQ(root)
}

func (defaults *Defaults) DefaultOf(path, mode, platform string) ([]byte, error) {
	root, err := defaults.renderNode(mode, platform)
	if err != nil {
		return nil, err
	}
	value, err := getStringPath(root, strings.TrimPrefix(path, "."))
	if err != nil || isNull(value) {
		return nil, ErrUnsupportedDefaults
	}
	return rawJQ(value)
}

func (defaults *Defaults) NewInstall(platform string) ([]byte, error) {
	rendered, err := defaults.renderNode("new", platform)
	if err != nil {
		return nil, err
	}
	materialize, ok := objectValue(defaults.table, "materialize")
	if !ok || materialize.array == nil {
		return nil, ErrUnsupportedDefaults
	}
	paths := make([]string, 0, len(materialize.array)+2)
	for _, item := range materialize.array {
		path, ok := item.value.(string)
		if !ok {
			return nil, ErrUnsupportedDefaults
		}
		paths = append(paths, path)
	}
	paths = append(paths, "monero.clearnet_initial_sync", "tari.clearnet_initial_sync")
	result := node{object: []member{}}
	for _, path := range paths {
		value, pathErr := getStringPath(rendered, path)
		if pathErr != nil {
			return nil, pathErr
		}
		if pathErr = setStringPath(&result, path, value); pathErr != nil {
			return nil, pathErr
		}
	}
	return prettyJQ(result)
}

func (defaults *Defaults) Get(path string, configRaw []byte, platform string) ([]byte, error) {
	fallbacks, err := defaults.renderNode("legacy", platform)
	if err != nil {
		return nil, err
	}
	path = strings.TrimPrefix(path, ".")
	fallback, err := getStringPath(fallbacks, path)
	if err != nil {
		return nil, err
	}
	document, err := ParseDocument(configRaw)
	if err != nil || document == nil || duplicateError(document.root, "") != "" {
		return nil, ErrUnsupportedDefaults
	}
	value, err := getStringPath(document.root, path)
	if err != nil {
		return nil, err
	}
	if isNull(value) {
		value = fallback
	}
	return rawJQ(value)
}

func (defaults *Defaults) renderNode(mode, platform string) (node, error) {
	if defaults == nil {
		return node{}, ErrUnsupportedDefaults
	}
	values, valuesOK := objectValue(defaults.table, "values")
	appliance, applianceOK := objectValue(defaults.table, "appliance")
	if !valuesOK || values.object == nil || !applianceOK || appliance.object == nil {
		return node{}, ErrUnsupportedDefaults
	}
	result := cloneNode(values)
	if platform == "appliance" {
		result = mergeNodes(result, appliance)
	}
	if mode != "legacy" {
		return result, nil
	}
	entries, ok := objectValue(defaults.table, "LEGACY_ABSENT")
	if !ok || entries.array == nil {
		return node{}, ErrUnsupportedDefaults
	}
	for _, entry := range entries.array {
		pathNode, hasPath := objectValue(entry, "path")
		value, hasValue := objectValue(entry, "value")
		path, pathOK := pathNode.value.(string)
		if entry.object == nil || !hasPath || !pathOK || !hasValue {
			return node{}, ErrUnsupportedDefaults
		}
		entryPlatform, hasPlatform := objectValue(entry, "platform")
		applies := !hasPlatform || isNull(entryPlatform) || entryPlatform.value == false
		if !applies {
			candidate, stringPlatform := entryPlatform.value.(string)
			applies = stringPlatform && candidate == platform
		}
		if applies {
			if err := setStringPath(&result, path, value); err != nil {
				return node{}, err
			}
		}
	}
	return result, nil
}

func validDefaultsTable(table node) bool {
	if table.object == nil {
		return false
	}
	values, valuesOK := objectValue(table, "values")
	appliance, applianceOK := objectValue(table, "appliance")
	materialize, materializeOK := objectValue(table, "materialize")
	legacy, legacyOK := objectValue(table, "LEGACY_ABSENT")
	if !valuesOK || values.object == nil || !applianceOK || appliance.object == nil || !materializeOK || materialize.array == nil || !legacyOK || legacy.array == nil {
		return false
	}
	for _, item := range materialize.array {
		if _, ok := item.value.(string); !ok {
			return false
		}
	}
	for _, entry := range legacy.array {
		path, hasPath := objectValue(entry, "path")
		_, hasValue := objectValue(entry, "value")
		if entry.object == nil || !hasPath || !hasValue {
			return false
		}
		if _, ok := path.value.(string); !ok {
			return false
		}
	}
	return true
}

func objectValue(current node, key string) (node, bool) {
	if current.object == nil {
		return node{}, false
	}
	for _, item := range current.object {
		if item.key == key {
			return item.value, true
		}
	}
	return node{}, false
}

func mergeNodes(left, right node) node {
	if left.object == nil || right.object == nil {
		return cloneNode(right)
	}
	result := cloneNode(left)
	for _, rightMember := range right.object {
		found := false
		for index := range result.object {
			if result.object[index].key == rightMember.key {
				result.object[index].value = mergeNodes(result.object[index].value, rightMember.value)
				found = true
				break
			}
		}
		if !found {
			result.object = append(result.object, member{key: rightMember.key, value: cloneNode(rightMember.value)})
		}
	}
	return result
}

func getStringPath(root node, path string) (node, error) {
	current := root
	for _, part := range splitStringPath(path) {
		if isNull(current) {
			return node{}, nil
		}
		if current.object == nil {
			return node{}, ErrUnsupportedDefaults
		}
		next, ok := objectValue(current, part)
		if !ok {
			return node{}, nil
		}
		current = next
	}
	return cloneNode(current), nil
}

func setStringPath(root *node, path string, value node) error {
	current := root
	parts := splitStringPath(path)
	if len(parts) == 0 {
		*root = cloneNode(value)
		return nil
	}
	for index, part := range parts {
		if isNull(*current) {
			current.object = []member{}
		}
		if current.object == nil {
			return ErrUnsupportedDefaults
		}
		for memberIndex := range current.object {
			if current.object[memberIndex].key != part {
				continue
			}
			if index == len(parts)-1 {
				current.object[memberIndex].value = cloneNode(value)
				return nil
			}
			current = &current.object[memberIndex].value
			goto nextPart
		}
		if index == len(parts)-1 {
			current.object = append(current.object, member{key: part, value: cloneNode(value)})
			return nil
		}
		current.object = append(current.object, member{key: part, value: node{object: []member{}}})
		current = &current.object[len(current.object)-1].value
	nextPart:
	}
	return nil
}

func splitStringPath(path string) []string {
	if path == "" {
		return []string{}
	}
	return strings.Split(path, ".")
}

func cloneNode(current node) node {
	result := node{value: current.value}
	if current.object != nil {
		result.object = make([]member, len(current.object))
		for index, item := range current.object {
			result.object[index] = member{key: item.key, value: cloneNode(item.value)}
		}
	}
	if current.array != nil {
		result.array = make([]node, len(current.array))
		for index, item := range current.array {
			result.array[index] = cloneNode(item)
		}
	}
	return result
}

func isNull(current node) bool {
	return current.value == nil && current.object == nil && current.array == nil
}
