package wizard

import (
	"fmt"
	"sort"
	"strings"
)

type configAttributeError struct{ message string }

func (e configAttributeError) Error() string { return e.message }

func EditorLeafPaths(reference, prefix *ConfigValue, includeArrays bool) (*ConfigValue, error) {
	if reference == nil || reference.Kind != "dict" {
		return nil, configAttributeError{fmt.Sprintf("'%s' object has no attribute 'items'", configPythonType(reference))}
	}
	parts, err := editorStringList(prefix, "prefix", true)
	if err != nil {
		return nil, err
	}
	paths := make([]string, 0)
	editorWalkLeaves(reference, parts, includeArrays, len(parts) == 0, &paths)
	return configStrings(paths), nil
}

func EditorApprovalPaths(reference, freePaths, confirmPaths, namedPaths *ConfigValue) (*ConfigValue, error) {
	leaves, err := editorLeafStrings(reference, false)
	if err != nil {
		return nil, err
	}
	free, err := editorStringSet(freePaths, "free_paths")
	if err != nil {
		return nil, err
	}
	confirm, err := editorStringSet(confirmPaths, "confirm_paths")
	if err != nil {
		return nil, err
	}
	named, err := editorStringSet(namedPaths, "approval_named")
	if err != nil {
		return nil, err
	}
	paths := make([]string, 0)
	for _, path := range leaves {
		if named[path] && !free[path] && !confirm[path] && !strings.HasPrefix(path, "ssh.") {
			paths = append(paths, path)
		}
	}
	sort.Strings(paths)
	return configStrings(paths), nil
}

func EditorConfirmedPaths(reference, freePaths, confirmPaths, approvalPaths *ConfigValue) (*ConfigValue, error) {
	leaves, err := editorLeafStrings(reference, false)
	if err != nil {
		return nil, err
	}
	classified := make(map[string]bool)
	for _, input := range []struct {
		name  string
		value *ConfigValue
	}{
		{"free_paths", freePaths},
		{"confirm_paths", confirmPaths},
		{"approval_paths", approvalPaths},
	} {
		values, listErr := editorStringSet(input.value, input.name)
		if listErr != nil {
			return nil, listErr
		}
		for path := range values {
			classified[path] = true
		}
	}
	paths := make([]string, 0)
	for _, path := range leaves {
		if !classified[path] && !strings.HasPrefix(path, "ssh.") {
			paths = append(paths, path)
		}
	}
	sort.Strings(paths)
	return configStrings(paths), nil
}

func EditorMissingDefaults(reference, host *ConfigValue) (*ConfigValue, error) {
	leaves, err := editorLeafStrings(reference, true)
	if err != nil {
		return nil, err
	}
	missing := make([]string, 0)
	for _, path := range leaves {
		if !editorDottedPresent(host, strings.Split(path, ".")) {
			missing = append(missing, path)
		}
	}
	return configStrings(missing), nil
}

func EditorLastApplyIndex(entries *ConfigValue) (*ConfigValue, error) {
	if entries == nil || entries.Kind != "list" {
		return nil, configTypeError{"entries must be a list"}
	}
	for index, entry := range entries.Items {
		if entry == nil || entry.Kind != "dict" {
			return nil, configAttributeError{fmt.Sprintf("'%s' object has no attribute 'get'", configPythonType(entry))}
		}
		action, _ := entry.Field("action")
		status, _ := entry.Field("status")
		if editorStringIn(action, "commit", "commit-confirmed", "commit-approved") && editorStringIn(status, "applied", "failed") {
			return &ConfigValue{Kind: "int", Text: fmt.Sprintf("%d", index)}, nil
		}
	}
	return configNull(), nil
}

func EditorMetadata(arguments *ConfigValue) (*ConfigValue, error) {
	reference, err := editorRequiredField(arguments, "reference")
	if err != nil {
		return nil, err
	}
	approvalFree, err := editorRequiredField(arguments, "approval_free")
	if err != nil {
		return nil, err
	}
	confirmedFree, err := editorRequiredField(arguments, "confirmed_free")
	if err != nil {
		return nil, err
	}
	explicitConfirm, err := editorRequiredField(arguments, "explicit_confirm")
	if err != nil {
		return nil, err
	}
	approvalNamed, err := editorRequiredField(arguments, "approval_named")
	if err != nil {
		return nil, err
	}
	approval, err := EditorApprovalPaths(reference, approvalFree, explicitConfirm, approvalNamed)
	if err != nil {
		return nil, err
	}
	remainingConfirmed, err := EditorConfirmedPaths(reference, confirmedFree, explicitConfirm, approval)
	if err != nil {
		return nil, err
	}
	confirmedSet, err := editorStringSet(explicitConfirm, "explicit_confirm")
	if err != nil {
		return nil, err
	}
	for _, path := range editorStrings(remainingConfirmed) {
		confirmedSet[path] = true
	}
	confirmedPaths := make([]string, 0, len(confirmedSet))
	for path := range confirmedSet {
		confirmedPaths = append(confirmedPaths, path)
	}
	sort.Strings(confirmedPaths)
	confirmed := configStrings(confirmedPaths)
	host, err := editorRequiredField(arguments, "host")
	if err != nil {
		return nil, err
	}
	defaults, err := EditorMissingDefaults(reference, host)
	if err != nil {
		return nil, err
	}
	entries, err := editorRequiredField(arguments, "entries")
	if err != nil {
		return nil, err
	}
	lastApply, err := EditorLastApplyIndex(entries)
	if err != nil {
		return nil, err
	}
	version, err := editorVersionFromArguments(arguments)
	if err != nil {
		return nil, err
	}
	popVersion, _ := version.Field("pop_version")
	newer, _ := version.Field("newer")
	return editorDict(
		editorField("confirm_keys", confirmed),
		editorField("approval_keys", approval),
		editorField("default_keys", defaults),
		editorField("last_apply_index", lastApply),
		editorField("pop_version", popVersion),
		editorField("newer", newer),
	), nil
}

func editorLeafStrings(reference *ConfigValue, includeArrays bool) ([]string, error) {
	value, err := EditorLeafPaths(reference, nil, includeArrays)
	if err != nil {
		return nil, err
	}
	return editorStrings(value), nil
}

func editorStrings(value *ConfigValue) []string {
	items := make([]string, len(value.Items))
	for index, item := range value.Items {
		items[index] = item.Text
	}
	return items
}

func editorWalkLeaves(node *ConfigValue, prefix []string, includeArrays, root bool, paths *[]string) {
	for _, field := range node.Fields {
		if strings.HasPrefix(field.Key, "_") || (root && field.Key == "config_version") {
			continue
		}
		path := append(append([]string{}, prefix...), field.Key)
		if field.Value.Kind == "dict" && !editorSecretSentinel(field.Value) {
			editorWalkLeaves(field.Value, path, includeArrays, false, paths)
		} else if includeArrays || field.Value.Kind != "list" {
			*paths = append(*paths, strings.Join(path, "."))
		}
	}
}

func editorSecretSentinel(value *ConfigValue) bool {
	secret, ok := value.Field("__secret__")
	return ok && secret.Kind == "bool" && secret.Bool
}

func editorDottedPresent(value *ConfigValue, path []string) bool {
	node := value
	for _, key := range path {
		if node == nil || node.Kind != "dict" {
			return false
		}
		var ok bool
		node, ok = node.Field(key)
		if !ok {
			return false
		}
	}
	return true
}

func editorStringSet(value *ConfigValue, name string) (map[string]bool, error) {
	values, err := editorStringList(value, name, false)
	if err != nil {
		return nil, err
	}
	set := make(map[string]bool, len(values))
	for _, item := range values {
		set[item] = true
	}
	return set, nil
}

func editorStringList(value *ConfigValue, name string, optional bool) ([]string, error) {
	if optional && value == nil {
		return []string{}, nil
	}
	if value == nil || value.Kind != "list" {
		if optional && value != nil && value.Kind == "null" {
			return []string{}, nil
		}
		return nil, configTypeError{fmt.Sprintf("%s must be a list", name)}
	}
	items := make([]string, len(value.Items))
	for index, item := range value.Items {
		if item == nil || item.Kind != "str" {
			return nil, configTypeError{fmt.Sprintf("%s must contain strings", name)}
		}
		items[index] = item.Text
	}
	return items, nil
}

func editorRequiredField(arguments *ConfigValue, name string) (*ConfigValue, error) {
	if arguments == nil || arguments.Kind != "dict" {
		return nil, configTypeError{"editor arguments must be an object"}
	}
	value, ok := arguments.Field(name)
	if !ok {
		return nil, configKeyError{name}
	}
	return value, nil
}

func editorStringIn(value *ConfigValue, choices ...string) bool {
	if value == nil || value.Kind != "str" {
		return false
	}
	for _, choice := range choices {
		if value.Text == choice {
			return true
		}
	}
	return false
}

func configPythonType(value *ConfigValue) string {
	if value == nil {
		return "NoneType"
	}
	return map[string]string{
		"null": "NoneType", "bool": "bool", "int": "int", "float": "float",
		"str": "str", "list": "list", "dict": "dict",
	}[value.Kind]
}

func editorField(key string, value *ConfigValue) ConfigField {
	return ConfigField{Key: key, Value: value}
}

func editorDict(fields ...ConfigField) *ConfigValue {
	return &ConfigValue{Kind: "dict", Fields: fields}
}
