package controlhttp

import (
	"fmt"

	"github.com/p2pool-starter-stack/pithead/go/internal/dashboard/wizard"
)

type protocolError struct {
	kind    string
	message string
}

func (e protocolError) Error() string { return e.message }

func valueError(message string) error { return protocolError{kind: "ValueError", message: message} }
func typeError(message string) error  { return protocolError{kind: "TypeError", message: message} }

func isString(value *wizard.ConfigValue, expected string) bool {
	return value != nil && value.Kind == "str" && value.Text == expected
}

func valueText(value *wizard.ConfigValue) string {
	if value == nil {
		return ""
	}
	return value.Text
}

func nullValue() *wizard.ConfigValue { return &wizard.ConfigValue{Kind: "null"} }
func stringValue(value string) *wizard.ConfigValue {
	return &wizard.ConfigValue{Kind: "str", Text: value}
}
func dictValue() *wizard.ConfigValue { return &wizard.ConfigValue{Kind: "dict"} }

func textResult(status int, text string) Result {
	return Result{Status: status, Text: stringValue(text)}
}

func statusBody() *wizard.ConfigValue {
	return &wizard.ConfigValue{Kind: "dict", Fields: []wizard.ConfigField{{
		Key: "status", Value: stringValue("pending"),
	}}}
}

func pendingBody(id *wizard.ConfigValue) *wizard.ConfigValue {
	return &wizard.ConfigValue{Kind: "dict", Fields: []wizard.ConfigField{
		{Key: "id", Value: id.Clone()},
		{Key: "status", Value: stringValue("pending")},
	}}
}

func errorBody(message string) *wizard.ConfigValue {
	return &wizard.ConfigValue{Kind: "dict", Fields: []wizard.ConfigField{{
		Key: "error", Value: stringValue(message),
	}}}
}

func protocolFailure(err error) wireError {
	if typed, ok := err.(protocolError); ok {
		return wireError{Kind: typed.kind, Message: typed.message}
	}
	return wireError{Kind: "ValueError", Message: fmt.Sprint(err)}
}
