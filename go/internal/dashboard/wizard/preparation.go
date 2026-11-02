package wizard

import "fmt"

type PreparationRequest struct {
	Phase          string       `json:"phase"`
	Raw            bool         `json:"raw"`
	Config         *ConfigValue `json:"config"`
	Reference      *ConfigValue `json:"reference"`
	Defaults       *ConfigValue `json:"defaults"`
	Previous       *ConfigValue `json:"previous"`
	Changes        *ConfigValue `json:"changes"`
	LegacyDefaults *ConfigValue `json:"legacy_defaults"`
	DefaultHost    *ConfigValue `json:"default_host"`
}

type PreparationResult struct {
	Next    string       `json:"next"`
	Config  *ConfigValue `json:"config,omitempty"`
	Changes *ConfigValue `json:"changes,omitempty"`
}

func HandlePreparation(request PreparationRequest) (PreparationResult, error) {
	switch request.Phase {
	case "source":
		next := "build"
		if request.Raw {
			next = "parse"
		}
		return PreparationResult{Next: next}, nil
	case "object":
		if request.Config == nil || request.Config.Kind != "dict" {
			return PreparationResult{}, ValidationError{"the top level must be a JSON object"}
		}
		return preparationResult("prepare", request.Config, request.Changes), nil
	case "prepare":
		config, changes, err := PrepareConfig(request.Config, request.Reference, request.LegacyDefaults, true)
		if err != nil {
			return PreparationResult{}, err
		}
		return preparationResult("previous", config, configStrings(changes)), nil
	case "previous":
		next := "defaults"
		if request.Previous.PythonTruth() {
			next = "validate"
		}
		return preparationResult(next, request.Config, request.Changes), nil
	case "defaults":
		defaults, _, err := PrepareConfig(request.Defaults, request.Reference, request.LegacyDefaults, false)
		if err != nil {
			return PreparationResult{}, err
		}
		return preparationResult("validate", DeepMerge(defaults, request.Config), request.Changes), nil
	case "validate":
		if err := ValidateMachineName(request.Config, request.Previous, request.DefaultHost); err != nil {
			return PreparationResult{}, err
		}
		return preparationResult("ready", request.Config, request.Changes), nil
	default:
		return PreparationResult{}, ValidationError{fmt.Sprintf("unsupported wizard preparation phase: %s", request.Phase)}
	}
}

func preparationResult(next string, config, changes *ConfigValue) PreparationResult {
	return PreparationResult{Next: next, Config: config.Clone(), Changes: changes.Clone()}
}
