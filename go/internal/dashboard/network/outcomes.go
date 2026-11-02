package network

import (
	"encoding/json"
	"errors"
	"unicode/utf8"
)

const (
	maxOutcomeRows    = 256
	maxTerminalValues = 64
	maxOutcomeText    = 256
)

type outcomeRow struct {
	IDString   *bool           `json:"id_string"`
	IDNonempty *bool           `json:"id_nonempty"`
	StatusKind *string         `json:"status_kind"`
	Status     json.RawMessage `json:"status,omitempty"`
}

type outcomeRequest struct {
	Operation string        `json:"operation"`
	Rows      *[]outcomeRow `json:"rows"`
	Terminal  *[]*string    `json:"terminal"`
}

func controlOutcomes(request outcomeRequest) ([]bool, error) {
	if request.Rows == nil || request.Terminal == nil {
		return nil, errors.New("missing control outcome input")
	}
	if len(*request.Rows) > maxOutcomeRows {
		return nil, errors.New("control outcome row count exceeds limit")
	}
	if len(*request.Terminal) > maxTerminalValues {
		return nil, errors.New("terminal vocabulary count exceeds limit")
	}
	terminal := make(map[string]struct{}, len(*request.Terminal))
	for _, status := range *request.Terminal {
		if status == nil || !validOutcomeText(*status) {
			return nil, errors.New("invalid terminal status")
		}
		terminal[*status] = struct{}{}
	}
	result := make([]bool, len(*request.Rows))
	for index, row := range *request.Rows {
		if row.IDString == nil || row.IDNonempty == nil || row.StatusKind == nil {
			return nil, errors.New("missing control outcome metadata")
		}
		switch *row.StatusKind {
		case "string":
			if len(row.Status) == 0 || row.Status[0] != '"' {
				return nil, errors.New("invalid control outcome status")
			}
			var status string
			if err := json.Unmarshal(row.Status, &status); err != nil || !validOutcomeText(status) {
				return nil, errors.New("invalid control outcome status")
			}
			_, terminalStatus := terminal[status]
			result[index] = *row.IDString && *row.IDNonempty && terminalStatus
		case "other":
			if len(row.Status) != 0 {
				return nil, errors.New("unexpected control outcome status")
			}
		default:
			return nil, errors.New("invalid control outcome status kind")
		}
	}
	return result, nil
}

func validOutcomeText(value string) bool {
	return utf8.ValidString(value) && len(value) <= maxOutcomeText
}
