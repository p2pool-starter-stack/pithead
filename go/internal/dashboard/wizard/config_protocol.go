package wizard

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
)

type ConfigRequest struct {
	Operation      string       `json:"operation"`
	Config         *ConfigValue `json:"config"`
	Reference      *ConfigValue `json:"reference"`
	LegacyDefaults *ConfigValue `json:"legacy_defaults"`
	Reject         bool         `json:"reject"`
	Base           *ConfigValue `json:"base"`
	Over           *ConfigValue `json:"over"`
	Previous       *ConfigValue `json:"previous"`
	DefaultHost    *ConfigValue `json:"default_host"`
	Changes        *ConfigValue `json:"changes"`
	Attempt        *ConfigValue `json:"attempt"`
	Disks          *ConfigValue `json:"disks"`
	Mode           *ConfigValue `json:"mode"`
}

type preparedConfigResult struct {
	Config  *ConfigValue `json:"config"`
	Changes *ConfigValue `json:"changes"`
}

type recoveryResult struct {
	Remembered *ConfigValue `json:"remembered"`
	Attempt    *ConfigValue `json:"attempt"`
	Mode       string       `json:"mode"`
}

func RunConfig(input io.Reader, output io.Writer) error {
	scanner := bufio.NewScanner(input)
	scanner.Buffer(make([]byte, 4096), 64<<20)
	for scanner.Scan() {
		var request ConfigRequest
		response := Response{}
		if err := json.NewDecoder(bytes.NewReader(scanner.Bytes())).Decode(&request); err != nil {
			response.Error = wireError(err)
		} else {
			value, err := handleConfigRequest(request)
			if err != nil {
				response.Error = configProtocolError(err)
			} else if raw, marshalErr := json.Marshal(value); marshalErr != nil {
				response.Error = wireError(marshalErr)
			} else {
				response = Response{OK: true, Value: raw}
			}
		}
		if err := writeResponse(output, response); err != nil {
			return err
		}
	}
	return scanner.Err()
}

func handleConfigRequest(request ConfigRequest) (any, error) {
	switch request.Operation {
	case "prepare":
		config, changes, err := PrepareConfig(request.Config, request.Reference, request.LegacyDefaults, request.Reject)
		return preparedConfigResult{Config: config, Changes: configStrings(changes)}, err
	case "merge":
		return DeepMerge(request.Base, request.Over), nil
	case "strip":
		return StripDefaults(request.Config, request.Reference), nil
	case "name":
		return nil, ValidateMachineName(request.Config, request.Previous, request.DefaultHost)
	case "recovery":
		remembered, attempt, mode, err := RecoveryState(request.Changes, request.Attempt, request.Disks, request.Mode)
		return recoveryResult{Remembered: configStrings(remembered), Attempt: attempt, Mode: mode}, err
	case "editor-leaves":
		return editorLeavesFromArguments(request.Config)
	case "editor-approval":
		return editorApprovalFromArguments(request.Config)
	case "editor-confirmed":
		return editorConfirmedFromArguments(request.Config)
	case "editor-defaults":
		return editorDefaultsFromArguments(request.Config)
	case "editor-last-apply":
		return editorLastApplyFromArguments(request.Config)
	case "editor-version":
		return editorVersionFromArguments(request.Config)
	case "editor-metadata":
		return EditorMetadata(request.Config)
	case "audit-diff":
		return auditDiff(request.Config)
	case "audit-unexplained":
		return auditUnexplained(request.Config)
	case "audit-recent":
		return auditRecent(request.Config)
	case "audit-mirror":
		return auditMirror(request.Config)
	default:
		return nil, ValidationError{fmt.Sprintf("unsupported wizard config operation: %s", request.Operation)}
	}
}

func configProtocolError(err error) *Error {
	var validation ValidationError
	var key configKeyError
	var typeError configTypeError
	var attributeError configAttributeError
	switch {
	case errors.As(err, &validation):
		return &Error{Kind: "ValueError", Message: err.Error()}
	case errors.As(err, &key):
		return &Error{Kind: "KeyError", Message: key.key}
	case errors.As(err, &typeError):
		return &Error{Kind: "TypeError", Message: err.Error()}
	case errors.As(err, &attributeError):
		return &Error{Kind: "AttributeError", Message: err.Error()}
	default:
		return wireError(err)
	}
}
