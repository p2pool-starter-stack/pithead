package storage

import (
	"context"
	"database/sql"
	"encoding/base64"
	"encoding/json"
	"math"
	"strings"
)

type sqlResult struct {
	Columns   []string `json:"columns"`
	Rows      [][]any  `json:"rows"`
	Rowcount  int64    `json:"rowcount"`
	Lastrowid int64    `json:"lastrowid"`
}

type parameterError struct {
	kind, message string
}

func (e *parameterError) Error() string { return e.message }

func (s *session) execute(ctx context.Context, statement string, parameters []any) (sqlResult, error) {
	result := sqlResult{Rowcount: -1}
	args := make([]any, len(parameters))
	for index, value := range parameters {
		var err error
		args[index], err = sqlValue(value)
		if err != nil {
			return result, err
		}
	}
	fields := strings.Fields(statement)
	if len(fields) == 0 {
		return result, nil
	}
	verb := strings.ToUpper(fields[0])
	if verb == "INSERT" || verb == "REPLACE" || verb == "UPDATE" || verb == "DELETE" {
		if err := s.begin(ctx); err != nil {
			return result, err
		}
	}
	if verb == "SELECT" || verb == "PRAGMA" || verb == "WITH" || verb == "EXPLAIN" {
		var rows *sql.Rows
		var err error
		if s.tx != nil {
			rows, err = s.tx.QueryContext(ctx, statement, args...)
		} else {
			rows, err = s.store.QueryContext(ctx, statement, args...)
		}
		if err != nil {
			return result, err
		}
		defer rows.Close()
		result.Columns, err = rows.Columns()
		if err != nil {
			return result, err
		}
		result.Rows = make([][]any, 0)
		for rows.Next() {
			row := make([]any, len(result.Columns))
			targets := make([]any, len(row))
			for index := range row {
				targets[index] = &row[index]
			}
			if err := rows.Scan(targets...); err != nil {
				return result, err
			}
			result.Rows = append(result.Rows, row)
		}
		return result, rows.Err()
	}
	var execution sql.Result
	var err error
	if s.tx != nil {
		execution, err = s.tx.ExecContext(ctx, statement, args...)
	} else {
		execution, err = s.store.ExecContext(ctx, statement, args...)
	}
	if err != nil {
		return result, err
	}
	result.Rowcount, err = execution.RowsAffected()
	if err != nil {
		return result, err
	}
	result.Lastrowid, err = execution.LastInsertId()
	if verb != "INSERT" && verb != "REPLACE" && verb != "UPDATE" && verb != "DELETE" {
		result.Rowcount = -1
	}
	return result, err
}

func sqlValue(value any) (any, error) {
	switch value := value.(type) {
	case json.Number:
		if integer, err := value.Int64(); err == nil {
			return integer, nil
		}
		if !strings.ContainsAny(string(value), ".eE") {
			return nil, &parameterError{"OverflowError", "Python int too large to convert to SQLite INTEGER"}
		}
		return value.Float64()
	case map[string]any:
		if encoded, ok := value["$bytes"].(string); ok && len(value) == 1 {
			return base64.StdEncoding.DecodeString(encoded)
		}
		if number, ok := value["$float"].(string); ok && len(value) == 1 {
			switch number {
			case "nan":
				return math.NaN(), nil
			case "inf":
				return math.Inf(1), nil
			case "-inf":
				return math.Inf(-1), nil
			}
		}
		return nil, &parameterError{"ProgrammingError", "unsupported SQLite parameter type"}
	default:
		return value, nil
	}
}

func wireValue(value any) any {
	switch value := value.(type) {
	case []byte:
		return map[string]any{"$bytes": base64.StdEncoding.EncodeToString(value)}
	case float64:
		if math.IsNaN(value) {
			return map[string]any{"$float": "nan"}
		}
		if math.IsInf(value, 1) {
			return map[string]any{"$float": "inf"}
		}
		if math.IsInf(value, -1) {
			return map[string]any{"$float": "-inf"}
		}
	case [][]any:
		rows := make([]any, len(value))
		for index, row := range value {
			rows[index] = wireValue(row)
		}
		return rows
	case []any:
		result := make([]any, len(value))
		for index, item := range value {
			result[index] = wireValue(item)
		}
		return result
	case sqlResult:
		return map[string]any{"columns": value.Columns, "rows": wireValue(value.Rows), "rowcount": value.Rowcount, "lastrowid": value.Lastrowid}
	}
	return value
}
