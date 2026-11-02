package fleet

import (
	"encoding/json"
	"fmt"
)

type preserveReportRow struct {
	index int
	kind  string
	stamp any
}

func pollPreserveReports(request Request) (any, error) {
	values, err := detailArguments(request, 3)
	if err != nil {
		return nil, err
	}
	currentRows, err := array(values[0])
	if err != nil {
		return nil, err
	}
	nextRows, err := array(values[1])
	if err != nil {
		return nil, err
	}
	current := make(map[string]preserveReportRow, len(currentRows))
	for index, value := range currentRows {
		row, err := preserveRow(value)
		if err != nil {
			return nil, err
		}
		key, comparable, err := preserveKey(row[0], row[1])
		if err != nil {
			return preserveReportFailure(nil, err)
		}
		if comparable {
			current[key] = preserveReportRow{index: index, kind: row[2].(string), stamp: row[3]}
		}
	}
	replacements := make([]any, 0)
	for nextIndex, value := range nextRows {
		row, err := preserveRow(value)
		if err != nil {
			return nil, err
		}
		key, comparable, err := preserveKey(row[0], row[1])
		if err != nil {
			return preserveReportFailure(replacements, err)
		}
		old, found := current[key]
		if !comparable || !found || old.kind != "dict" {
			continue
		}
		_, oldValid, err := rigforgeFeedAge(old.stamp, values[2])
		if err != nil {
			return preserveReportFailure(replacements, err)
		}
		if !oldValid {
			continue
		}
		kind := row[2].(string)
		if kind != "dict" && kind != "falsy" {
			return preserveReportFailure(replacements, &PollError{Kind: "AttributeError", Message: fmt.Sprintf("'%s' object has no attribute 'get'", kind)})
		}
		_, nextValid, err := rigforgeFeedAge(row[3], values[2])
		if err != nil {
			return preserveReportFailure(replacements, err)
		}
		oldStamp := old.stamp.(string)
		newStamp, _ := row[3].(string)
		if !nextValid || oldStamp >= newStamp {
			replacements = append(replacements, []any{json.Number(fmt.Sprint(nextIndex)), json.Number(fmt.Sprint(old.index))})
		}
	}
	return map[string]any{"replacements": replacements, "error": nil}, nil
}

func preserveReportFailure(replacements []any, err error) (any, error) {
	detail, ok := err.(*PollError)
	if !ok || detail.Kind == "ValueError" {
		return nil, err
	}
	if replacements == nil {
		replacements = []any{}
	}
	return map[string]any{
		"replacements": replacements,
		"error":        map[string]any{"kind": detail.Kind, "message": detail.Message},
	}, nil
}

func preserveRow(value any) ([]any, error) {
	row, ok := value.([]any)
	if !ok || len(row) != 4 {
		return nil, pollValueError("preserve report rows must contain four values")
	}
	if _, ok := row[2].(string); !ok {
		return nil, pollValueError("preserve report kind must be a string")
	}
	return row, nil
}

func preserveKey(name, ip any) (string, bool, error) {
	left, leftComparable, err := preserveKeyPart(name)
	if err != nil {
		return "", false, err
	}
	right, rightComparable, err := preserveKeyPart(ip)
	if err != nil {
		return "", false, err
	}
	if !leftComparable || !rightComparable {
		return "", false, nil
	}
	return fmt.Sprintf("%d:%s%d:%s", len(left), left, len(right), right), true, nil
}

func preserveKeyPart(value any) (string, bool, error) {
	switch value := value.(type) {
	case nil:
		return "n", true, nil
	case string:
		return "s" + value, true, nil
	case []any:
		return "", false, &PollError{Kind: "TypeError", Message: "unhashable type: 'list'"}
	case map[string]any:
		return "", false, &PollError{Kind: "TypeError", Message: "unhashable type: 'dict'"}
	}
	number, ok := dynamicNumber(value)
	if !ok {
		return "", false, pollValueError("preserve report key must be a scalar")
	}
	if number.nan {
		return "", false, nil
	}
	if number.infinite != 0 {
		return fmt.Sprintf("i%d", number.infinite), true, nil
	}
	return "q" + number.rat.RatString(), true, nil
}
