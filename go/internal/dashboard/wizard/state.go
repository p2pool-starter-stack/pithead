package wizard

import "fmt"

type StateRequest struct {
	Phase          string       `json:"phase"`
	Reference      *ConfigValue `json:"reference"`
	Attempt        *ConfigValue `json:"attempt"`
	LegacyDefaults *ConfigValue `json:"legacy_defaults"`
	Changes        *ConfigValue `json:"changes"`
	Remembered     *ConfigValue `json:"remembered"`
	Defaults       *ConfigValue `json:"defaults"`
	Budget         *ConfigValue `json:"budget"`
	Error          *ConfigValue `json:"error"`
	Disks          *ConfigValue `json:"disks"`
	RigDefaults    *ConfigValue `json:"rig_defaults"`
	DataWiped      *ConfigValue `json:"data_wiped"`
	Handoff        *ConfigValue `json:"handoff"`
	SavedRole      *ConfigValue `json:"saved_role"`
	NodeProbe      *ConfigValue `json:"node_probe"`
	InstallAttempt *ConfigValue `json:"install_attempt"`
	AuthMode       *ConfigValue `json:"auth_mode"`
	RestoreEnabled *ConfigValue `json:"restore_enabled"`
	Config         *ConfigValue `json:"config"`
	Stage          string       `json:"stage"`
	Mode           string       `json:"mode"`
	Installer      bool         `json:"installer"`
	NewMachine     bool         `json:"new_machine"`
}

type StateResult struct {
	Next         string       `json:"next"`
	Attempt      *ConfigValue `json:"attempt,omitempty"`
	Changes      *ConfigValue `json:"changes,omitempty"`
	Remember     *bool        `json:"remember,omitempty"`
	ReadHandoff  *bool        `json:"read_handoff,omitempty"`
	NeedDefaults *bool        `json:"need_defaults,omitempty"`
	Config       *ConfigValue `json:"config,omitempty"`
	NewMachine   *bool        `json:"new_machine,omitempty"`
	Mode         string       `json:"mode,omitempty"`
	Body         *ConfigValue `json:"body,omitempty"`
}

func HandleState(request StateRequest) (StateResult, error) {
	switch request.Phase {
	case "prepare":
		reference := request.Reference
		if reference == nil || reference.Kind == "null" {
			reference = configDict()
		}
		attempt, changes, err := PrepareConfig(request.Attempt, reference, request.LegacyDefaults, false)
		if err != nil {
			return StateResult{}, err
		}
		remember := len(changes) != 0
		readHandoff := request.Stage == "handoff"
		needDefaults := !attempt.PythonTruth()
		return StateResult{
			Next: "config", Attempt: attempt, Changes: configStrings(changes),
			Remember: &remember, ReadHandoff: &readHandoff, NeedDefaults: &needDefaults,
		}, nil
	case "config":
		reference := request.Reference
		if reference == nil || reference.Kind == "null" {
			reference = configDict()
		}
		selected := request.Attempt
		newMachine := !selected.PythonTruth()
		if newMachine {
			selected = request.Defaults
		}
		mode := "setup"
		if request.Installer {
			mode = "installer"
		}
		return StateResult{
			Next: "response", Config: DeepMerge(reference, selected), NewMachine: &newMachine, Mode: mode,
		}, nil
	case "response":
		configChanges, err := stateChanges(request.Changes, request.Remembered)
		if err != nil {
			return StateResult{}, err
		}
		body := configDict()
		for _, field := range []ConfigField{
			{Key: "stage", Value: &ConfigValue{Kind: "str", Text: request.Stage}},
			{Key: "mode", Value: &ConfigValue{Kind: "str", Text: request.Mode}},
			{Key: "config", Value: stateValue(request.Config)},
			{Key: "reference", Value: stateValue(request.Reference)},
			{Key: "new_machine", Value: &ConfigValue{Kind: "bool", Bool: request.NewMachine}},
			{Key: "disk_budget", Value: stateValue(request.Budget)},
			{Key: "error", Value: stateValue(request.Error)},
			{Key: "disks", Value: stateValue(request.Disks)},
			{Key: "rig_defaults", Value: stateValue(request.RigDefaults)},
			{Key: "data_wiped", Value: stateValue(request.DataWiped)},
			{Key: "handoff", Value: stateValue(request.Handoff)},
			{Key: "saved_role", Value: stateValue(request.SavedRole)},
			{Key: "node_probe", Value: stateValue(request.NodeProbe)},
			{Key: "config_changes", Value: configChanges},
			{Key: "install_attempt", Value: stateValue(request.InstallAttempt)},
			{Key: "auth_mode", Value: stateValue(request.AuthMode)},
			{Key: "restore_enabled", Value: stateValue(request.RestoreEnabled)},
		} {
			body.Set(field.Key, field.Value)
		}
		return StateResult{Next: "ready", Body: body}, nil
	default:
		return StateResult{}, ValidationError{fmt.Sprintf("unsupported wizard state phase: %s", request.Phase)}
	}
}

func stateChanges(changes, remembered *ConfigValue) (*ConfigValue, error) {
	if changes == nil || changes.Kind != "list" || remembered == nil || remembered.Kind != "list" {
		return nil, configTypeError{"config changes must be lists"}
	}
	result := &ConfigValue{Kind: "list"}
	for _, value := range append(append([]*ConfigValue{}, changes.Items...), remembered.Items...) {
		if err := requireHashable(value); err != nil {
			return nil, err
		}
		if !containsValue(result.Items, value) {
			result.Items = append(result.Items, value.Clone())
		}
	}
	return result, nil
}

func stateValue(value *ConfigValue) *ConfigValue {
	if value == nil {
		return &ConfigValue{Kind: "null"}
	}
	return value.Clone()
}
