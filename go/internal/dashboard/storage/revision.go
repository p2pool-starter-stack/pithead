package storage

import (
	"context"
	"encoding/json"
	"errors"
	"math"
	"unicode/utf8"
)

const revisionTextLimit = 4096

func revisionText(value any, name string, nullable bool) (string, bool, error) {
	if value == nil && nullable {
		return "", true, nil
	}
	text, ok := value.(string)
	if !ok || !utf8.ValidString(text) || len(text) > revisionTextLimit || (!nullable && text == "") {
		return "", false, &parameterError{"ProgrammingError", name + " is invalid"}
	}
	return text, false, nil
}

func revisionNumeric(value any, name string) error {
	switch value := value.(type) {
	case json.Number:
		_, err := sqlValue(value)
		return err
	case map[string]any:
		if len(value) != 1 {
			break
		}
		if number, ok := value["$float"].(string); ok && (number == "nan" || number == "inf" || number == "-inf") {
			return nil
		}
	}
	return &parameterError{"ProgrammingError", name + " is invalid"}
}

func revisionScalar(value any) error {
	switch value := value.(type) {
	case nil, string, bool, json.Number:
		_, err := sqlValue(value)
		return err
	case map[string]any:
		_, err := sqlValue(value)
		return err
	default:
		return &parameterError{"ProgrammingError", "drift_from is invalid"}
	}
}

func revisionArgs(args []any, count int) error {
	if len(args) != count {
		return &parameterError{"ProgrammingError", "invalid worker revision parameter count"}
	}
	return nil
}

func (s *session) workerRevisionPrepare(ctx context.Context, args []any) (any, error) {
	if err := revisionArgs(args, 3); err != nil {
		return nil, err
	}
	worker, _, err := revisionText(args[0], "worker", false)
	if err != nil {
		return nil, err
	}
	revision, _, err := revisionText(args[1], "revision", false)
	if err != nil {
		return nil, err
	}
	changeID, nullChangeID, err := revisionText(args[2], "last_change_id", true)
	if err != nil {
		return nil, err
	}
	var currentChangeID any = changeID
	if nullChangeID {
		currentChangeID = nil
	}
	result, err := s.execute(ctx,
		"SELECT revision, last_change_id, drift_from FROM worker_config_revision WHERE worker = ?",
		[]any{worker},
	)
	if err != nil {
		return nil, err
	}
	response := map[string]any{"row": nil, "next_slot": nil}
	if len(result.Rows) == 0 {
		return response, nil
	}
	row := result.Rows[0]
	if len(row) != 3 {
		return nil, errors.New("invalid worker revision row")
	}
	response["row"] = row
	if storedRevision, ok := row[0].(string); ok && storedRevision == revision {
		response["next_slot"] = 2
	} else if revisionChangeIDEqual(row[1], currentChangeID) {
		response["next_slot"] = 0
	}
	return response, nil
}

func (s *session) workerRevisionWrite(ctx context.Context, args []any) (any, error) {
	if err := revisionArgs(args, 5); err != nil {
		return nil, err
	}
	worker, _, err := revisionText(args[0], "worker", false)
	if err != nil {
		return nil, err
	}
	revision, _, err := revisionText(args[1], "revision", false)
	if err != nil {
		return nil, err
	}
	changeID, nullChangeID, err := revisionText(args[2], "last_change_id", true)
	if err != nil {
		return nil, err
	}
	if err := revisionNumeric(args[3], "timestamp"); err != nil {
		return nil, err
	}
	if err := revisionScalar(args[4]); err != nil {
		return nil, err
	}
	var currentChangeID any = changeID
	if nullChangeID {
		currentChangeID = nil
	}
	_, err = s.execute(ctx,
		"INSERT OR REPLACE INTO worker_config_revision (worker, revision, last_change_id, ts, drift_from) VALUES (?, ?, ?, ?, ?)",
		[]any{worker, revision, currentChangeID, args[3], args[4]},
	)
	return nil, err
}

func (s *session) workerRevisionPrune(ctx context.Context, args []any) (any, error) {
	if err := revisionArgs(args, 1); err != nil {
		return nil, err
	}
	if err := revisionNumeric(args[0], "cutoff"); err != nil {
		return nil, err
	}
	_, err := s.execute(ctx, "DELETE FROM worker_config_revision WHERE ts < ?", args)
	return nil, err
}

func (s *session) workerRevisionDrift(ctx context.Context, args []any) (any, error) {
	if err := revisionArgs(args, 2); err != nil {
		return nil, err
	}
	worker, _, err := revisionText(args[0], "worker", false)
	if err != nil {
		return nil, err
	}
	revision, _, err := revisionText(args[1], "revision", false)
	if err != nil {
		return nil, err
	}
	result, err := s.execute(ctx,
		"SELECT revision, drift_from FROM worker_config_revision WHERE worker = ?",
		[]any{worker},
	)
	if err != nil {
		return nil, err
	}
	response := map[string]any{"row": nil, "visible": false}
	if len(result.Rows) == 0 || len(result.Rows[0]) != 2 {
		return response, nil
	}
	row := result.Rows[0]
	response["row"] = row
	storedRevision, ok := row[0].(string)
	if ok && storedRevision == revision && revisionTruthy(row[1]) {
		response["visible"] = true
	}
	return response, nil
}

func revisionChangeIDEqual(stored, current any) bool {
	if stored == nil || current == nil {
		return stored == nil && current == nil
	}
	storedText, storedOK := stored.(string)
	currentText, currentOK := current.(string)
	return storedOK && currentOK && storedText == currentText
}

func revisionTruthy(value any) bool {
	switch value := value.(type) {
	case nil:
		return false
	case bool:
		return value
	case string:
		return value != ""
	case []byte:
		return len(value) != 0
	case int64:
		return value != 0
	case float64:
		return value != 0 || math.IsNaN(value)
	default:
		return true
	}
}
