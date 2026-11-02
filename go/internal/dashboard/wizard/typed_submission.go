package wizard

import "fmt"

type TypedSubmissionRequest struct {
	Phase      string           `json:"phase"`
	Fields     map[string]Field `json:"fields"`
	Installer  bool             `json:"installer"`
	Disks      []map[string]any `json:"disks"`
	Configured bool             `json:"configured"`
	ProbeOK    bool             `json:"probe_ok"`
	Failure    *ConfigValue     `json:"failure"`
	Changes    *ConfigValue     `json:"changes"`
	Install    map[string]any   `json:"install"`
	Config     *ConfigValue     `json:"config"`
}

type TypedSubmissionResult struct {
	SubmissionResult
	Install       map[string]any `json:"install,omitempty"`
	IncludeReport bool           `json:"include_report,omitempty"`
}

type typedAcceptedBody struct {
	Status        string       `json:"status"`
	ConfigChanges *ConfigValue `json:"config_changes"`
	Warning       string       `json:"warning"`
}

type typedFailureBody struct {
	Error *ConfigValue `json:"error"`
}

func HandleTypedSubmission(request TypedSubmissionRequest) (TypedSubmissionResult, error) {
	switch request.Phase {
	case "start":
		stick := "0"
		if request.Fields["disk"].Text == "usb" {
			stick = "1"
		}
		return typedResult(SubmissionResult{
			Actions: []SubmissionAction{{Operation: "clear-host"}, {Operation: "text", Name: "stick", Text: stick}},
			Next:    "route",
		}), nil
	case "route":
		if request.Installer && request.Fields["wipe"].Text == "keep" && request.Fields["disk"].Text != "" {
			return typedNext("keep"), nil
		}
		return typedNext(typedRoleRoute(request.Fields)), nil
	case "keep":
		return handleTypedKeep(request)
	case "prepared":
		actions := []SubmissionAction{{Operation: "clear-sidecars"}}
		mode := request.Fields["auth_mode"].Text
		if mode == "auto" || mode == "set" || mode == "none" {
			actions = append(actions, SubmissionAction{Operation: "text", Name: "auth-mode", Text: mode})
		}
		return typedResult(SubmissionResult{Actions: actions, Next: "install"}), nil
	case "install":
		var install map[string]any
		if request.Installer {
			var err error
			install, err = ValidateInstallRequest(request.Fields, request.Disks)
			if err != nil {
				result, protocolErr := submissionInstallError(err)
				return typedResult(result), protocolErr
			}
		}
		return TypedSubmissionResult{SubmissionResult: SubmissionResult{Next: "probe"}, Install: install}, nil
	case "report":
		actions := []SubmissionAction{}
		if request.Configured {
			actions = append(actions, SubmissionAction{Operation: "report"})
		}
		return typedResult(SubmissionResult{Actions: actions, Next: "verdict"}), nil
	case "verdict":
		return handleTypedVerdict(request), nil
	case "failure":
		return TypedSubmissionResult{
			SubmissionResult: SubmissionResult{Status: 400, Body: typedFailureBody{Error: request.Failure}},
			IncludeReport:    true,
		}, nil
	case "accepted":
		changes := request.Changes
		if changes == nil {
			changes = configStrings(nil)
		}
		return typedResult(SubmissionResult{Status: 200, Body: typedAcceptedBody{
			Status: "accepted", ConfigChanges: changes, Warning: typedFastSyncWarning(request.Config),
		}}), nil
	default:
		return TypedSubmissionResult{}, ValidationError{fmt.Sprintf("unsupported typed wizard submission phase: %s", request.Phase)}
	}
}

func handleTypedKeep(request TypedSubmissionRequest) (TypedSubmissionResult, error) {
	byName := make(map[string]map[string]any, len(request.Disks))
	for _, disk := range request.Disks {
		name, ok := disk["name"]
		if !ok {
			return TypedSubmissionResult{}, formKeyError{"name"}
		}
		if text, ok := name.(string); ok {
			byName[text] = disk
		}
	}
	disk := request.Fields["disk"].Text
	selected, ok := byName[disk]
	if !ok {
		return typedResult(submissionError(400, "choose a disk from the list")), nil
	}
	state, ok := selected["state"]
	if !ok {
		return TypedSubmissionResult{}, formKeyError{"state"}
	}
	if state != "pithead-with-data" {
		return typedNext(typedRoleRoute(request.Fields)), nil
	}
	if request.Fields["confirm"].Text != disk {
		return typedResult(submissionError(400, fmt.Sprintf("type %s exactly to confirm", disk))), nil
	}
	actions := []SubmissionAction{
		{Operation: "clear-host"},
		{Operation: "clear-sidecars"},
		{Operation: "text", Name: "submission-staging", Text: "1"},
	}
	actions = appendInstallActions(actions, map[string]any{"disk": disk, "wipe": "keep"})
	actions = append(actions, SubmissionAction{Operation: "text", Name: "submission-active", Text: "1"})
	return typedResult(acceptedSubmission(actions)), nil
}

func handleTypedVerdict(request TypedSubmissionRequest) TypedSubmissionResult {
	actions := []SubmissionAction{}
	if !request.ProbeOK {
		actions = append(actions,
			SubmissionAction{Operation: "remember"},
			SubmissionAction{Operation: "attempt"},
			SubmissionAction{Operation: "remove", Name: "install-request"},
		)
		return typedResult(SubmissionResult{Actions: actions, Next: "failure"})
	}
	actions = append(actions,
		SubmissionAction{Operation: "text", Name: "submission-staging", Text: "1"},
		SubmissionAction{Operation: "remember"},
		SubmissionAction{Operation: "attempt"},
		SubmissionAction{Operation: "config"},
	)
	actions = appendInstallActions(actions, request.Install)
	actions = append(actions, SubmissionAction{Operation: "text", Name: "submission-active", Text: "1"})
	return typedResult(SubmissionResult{Actions: actions, Next: "accepted"})
}

func typedRoleRoute(fields map[string]Field) string {
	if fields["role"].Text == "rig" {
		return "rig"
	}
	return "config"
}

func typedFastSyncWarning(config *ConfigValue) string {
	networks := []string{}
	for _, chain := range []struct{ key, name string }{{"monero", "Monero"}, {"tari", "Tari"}} {
		section, ok := config.Field(chain.key)
		if !ok {
			continue
		}
		value, ok := section.Field("clearnet_initial_sync")
		if ok && value.Kind == "bool" && value.Bool {
			networks = append(networks, "the "+chain.name+" network")
		}
	}
	if len(networks) == 0 {
		return ""
	}
	warning := networks[0]
	if len(networks) == 2 {
		warning += " and " + networks[1]
	}
	return "Fast sync exposes your IP address to " + warning + " until the initial sync finishes."
}

func typedNext(next string) TypedSubmissionResult {
	return typedResult(SubmissionResult{Next: next})
}

func typedResult(result SubmissionResult) TypedSubmissionResult {
	return TypedSubmissionResult{SubmissionResult: result}
}
