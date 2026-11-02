package wizard

func editorLeavesFromArguments(arguments *ConfigValue) (*ConfigValue, error) {
	reference, err := editorRequiredField(arguments, "reference")
	if err != nil {
		return nil, err
	}
	prefix, _ := arguments.Field("prefix")
	includeArrays := false
	if include, ok := arguments.Field("include_arrays"); ok {
		if include.Kind != "bool" {
			return nil, configTypeError{"include_arrays must be a bool"}
		}
		includeArrays = include.Bool
	}
	return EditorLeafPaths(reference, prefix, includeArrays)
}

func editorApprovalFromArguments(arguments *ConfigValue) (*ConfigValue, error) {
	reference, err := editorRequiredField(arguments, "reference")
	if err != nil {
		return nil, err
	}
	free, err := editorRequiredField(arguments, "free_paths")
	if err != nil {
		return nil, err
	}
	confirm, err := editorRequiredField(arguments, "confirm_paths")
	if err != nil {
		return nil, err
	}
	named, err := editorRequiredField(arguments, "approval_named")
	if err != nil {
		return nil, err
	}
	return EditorApprovalPaths(reference, free, confirm, named)
}

func editorConfirmedFromArguments(arguments *ConfigValue) (*ConfigValue, error) {
	reference, err := editorRequiredField(arguments, "reference")
	if err != nil {
		return nil, err
	}
	free, err := editorRequiredField(arguments, "free_paths")
	if err != nil {
		return nil, err
	}
	confirm, err := editorRequiredField(arguments, "confirm_paths")
	if err != nil {
		return nil, err
	}
	approval, err := editorRequiredField(arguments, "approval_paths")
	if err != nil {
		return nil, err
	}
	return EditorConfirmedPaths(reference, free, confirm, approval)
}

func editorDefaultsFromArguments(arguments *ConfigValue) (*ConfigValue, error) {
	reference, err := editorRequiredField(arguments, "reference")
	if err != nil {
		return nil, err
	}
	host, err := editorRequiredField(arguments, "host")
	if err != nil {
		return nil, err
	}
	return EditorMissingDefaults(reference, host)
}

func editorLastApplyFromArguments(arguments *ConfigValue) (*ConfigValue, error) {
	entries, err := editorRequiredField(arguments, "entries")
	if err != nil {
		return nil, err
	}
	return EditorLastApplyIndex(entries)
}
