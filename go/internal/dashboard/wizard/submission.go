package wizard

import (
	"errors"
	"fmt"
	"strings"
)

type SubmissionRequest struct {
	Operation       string           `json:"operation"`
	Phase           string           `json:"phase"`
	Fields          map[string]Field `json:"fields"`
	Installer       bool             `json:"installer"`
	Disks           []map[string]any `json:"disks"`
	Upload          bool             `json:"upload"`
	Size            int64            `json:"size"`
	Limit           int64            `json:"limit"`
	PassphraseBytes int64            `json:"passphrase_bytes"`
	Encrypted       bool             `json:"encrypted"`
	Cleaned         bool             `json:"cleaned"`
}

type SubmissionResult struct {
	Actions []SubmissionAction `json:"actions,omitempty"`
	Status  int                `json:"status,omitempty"`
	Body    any                `json:"body,omitempty"`
	Next    string             `json:"next,omitempty"`
}

type SubmissionAction struct {
	Operation string   `json:"operation"`
	Name      string   `json:"name,omitempty"`
	Text      string   `json:"text,omitempty"`
	Pairs     [][2]any `json:"pairs,omitempty"`
	Volatile  bool     `json:"volatile,omitempty"`
}

func HandleSubmission(request SubmissionRequest) (SubmissionResult, error) {
	switch request.Operation {
	case "rig":
		return handleRigSubmission(request)
	case "restore":
		return handleRestoreSubmission(request)
	case "failure":
		return handleSubmissionFailure(request)
	default:
		return SubmissionResult{}, ValidationError{fmt.Sprintf("unsupported wizard submission operation: %s", request.Operation)}
	}
}

func handleRigSubmission(request SubmissionRequest) (SubmissionResult, error) {
	if request.Phase != "start" && request.Phase != "publish" {
		return SubmissionResult{}, ValidationError{fmt.Sprintf("unsupported rig submission phase: %s", request.Phase)}
	}
	if result := validateRigPool(request.Fields); result.Status != 0 {
		return result, nil
	}
	if request.Phase == "start" {
		return SubmissionResult{Next: "install"}, nil
	}

	var install map[string]any
	if request.Installer && request.Fields["disk"].Text != "usb" {
		var err error
		install, err = ValidateInstallRequest(request.Fields, request.Disks)
		if err != nil {
			return submissionInstallError(err)
		}
	}

	pool := request.Fields["rig_pool"].Text
	pairs := [][2]any{{"pool", pool}}
	if worker := request.Fields["rig_worker"].Text; worker != "" {
		pairs = append(pairs, [2]any{"worker", worker})
	}
	if password := request.Fields["rig_password"].Text; password != "" {
		pairs = append(pairs, [2]any{"stratum_password", password})
	}
	actions := []SubmissionAction{
		{Operation: "clear-host"},
		{Operation: "clear-sidecars"},
		{Operation: "text", Name: "submission-staging", Text: "1"},
		{Operation: "text", Name: "role", Text: "rig"},
		{Operation: "json", Name: "rig-request.json", Pairs: pairs},
	}
	actions = appendInstallActions(actions, install)
	actions = append(actions, SubmissionAction{Operation: "text", Name: "submission-active", Text: "1"})
	return acceptedSubmission(actions), nil
}

func validateRigPool(fields map[string]Field) SubmissionResult {
	pool := fields["rig_pool"]
	last := strings.LastIndex(pool.Text, ":")
	host, port := "", ""
	if last >= 0 {
		host, port = pool.Text[:last], pool.Text[last+1:]
	}
	if last < 0 || host == "" || port == "" || !pool.Digit {
		return submissionError(400, "enter the pool address as host:port — a Pithead answers on port 3333")
	}
	return SubmissionResult{}
}

func handleRestoreSubmission(request SubmissionRequest) (SubmissionResult, error) {
	switch request.Phase {
	case "start":
		actions := []SubmissionAction{
			{Operation: "clear-host"},
			{Operation: "text", Name: "stick", Text: "0"},
		}
		if !request.Upload {
			return SubmissionResult{Actions: actions, Status: 400, Body: map[string]string{"error": "choose a backup archive to upload"}}, nil
		}
		return SubmissionResult{Actions: actions, Next: "read-upload"}, nil
	case "validate":
		if request.Size > request.Limit {
			message := fmt.Sprintf("archive too large (max %d MB) — a Pithead backup holds only config, keys and the dashboard database, never the blockchains", request.Limit/(1024*1024))
			return submissionError(400, message), nil
		}
		return SubmissionResult{Next: "passphrase"}, nil
	case "passphrase":
		if request.PassphraseBytes > 4096 {
			return submissionError(400, "restore passphrase is too large"), nil
		}
		return SubmissionResult{Next: "install"}, nil
	case "publish":
		var install map[string]any
		if request.Installer {
			var err error
			install, err = ValidateInstallRequest(request.Fields, request.Disks)
			if err != nil {
				return submissionInstallError(err)
			}
		}
		actions := []SubmissionAction{
			{Operation: "clear-sidecars"},
			{Operation: "remove", Name: "last-attempt.json"},
			{Operation: "text", Name: "submission-staging", Text: "1"},
			{Operation: "passphrase", Name: "restore-passphrase", Volatile: true},
		}
		actions = appendInstallActions(actions, install)
		actions = append(actions,
			SubmissionAction{Operation: "archive", Name: "restore-archive", Volatile: !request.Encrypted},
			SubmissionAction{Operation: "text", Name: "submission-active", Text: "1"},
		)
		return acceptedSubmission(actions), nil
	default:
		return SubmissionResult{}, ValidationError{fmt.Sprintf("unsupported restore submission phase: %s", request.Phase)}
	}
}

func handleSubmissionFailure(request SubmissionRequest) (SubmissionResult, error) {
	var message string
	switch request.Phase {
	case "setup":
		message = "could not stage the setup submission; submit it again"
	case "restore":
		message = "could not stage the restore; submit it again"
	default:
		return SubmissionResult{}, ValidationError{fmt.Sprintf("unsupported submission failure phase: %s", request.Phase)}
	}
	if !request.Cleaned {
		message += "; temporary " + request.Phase + " files could not be cleared safely"
	}
	return submissionError(500, message), nil
}

func appendInstallActions(actions []SubmissionAction, install map[string]any) []SubmissionAction {
	if install == nil {
		return actions
	}
	disk := install["disk"].(string)
	wipe := install["wipe"].(string)
	return append(actions,
		SubmissionAction{Operation: "json", Name: "install-attempt.json", Pairs: [][2]any{{"disk", disk}, {"wipe", wipe}}},
		SubmissionAction{Operation: "text", Name: "install-request", Text: disk + "\t" + wipe},
	)
}

func submissionInstallError(err error) (SubmissionResult, error) {
	var validation ValidationError
	if errors.As(err, &validation) {
		return submissionError(400, err.Error()), nil
	}
	return SubmissionResult{}, err
}

func submissionError(status int, message string) SubmissionResult {
	return SubmissionResult{Status: status, Body: map[string]string{"error": message}}
}

func acceptedSubmission(actions []SubmissionAction) SubmissionResult {
	return SubmissionResult{Actions: actions, Status: 200, Body: map[string]string{"status": "accepted"}}
}
