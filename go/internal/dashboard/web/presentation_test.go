package web

import (
	"encoding/json"
	"testing"
)

func TestNativePresentationSections(t *testing.T) {
	for _, test := range []struct {
		field string
		raw   string
	}{
		{"workers", `{"helper":"fleet","operation":"build_workers","args":[[],null]}`},
		{"host_resources", `{"helper":"resources","operation":"build_host_resources","args":[{},[]],"now":100,"max_age":90}`},
	} {
		value, err := buildPresentation(test.field, json.RawMessage(test.raw))
		if err != nil || value == nil {
			t.Fatalf("%s = %#v, %v", test.field, value, err)
		}
	}
}

func TestPresentationCannotOverrideOtherStateFields(t *testing.T) {
	for _, test := range []struct {
		field string
		raw   string
	}{
		{"control_enabled", `{"helper":"fleet","operation":"build_control_enabled","args":[]}`},
		{"workers", `{"helper":"resources","operation":"build_workers","args":[[]]}`},
		{"workers", `{"helper":"fleet","operation":"_num","args":[true]}`},
		{"host_resources", `{"helper":"fleet","operation":"build_host_resources","args":[{},[]]}`},
		{"workers", `{`},
	} {
		if _, err := buildPresentation(test.field, json.RawMessage(test.raw)); err == nil {
			t.Fatalf("accepted %s: %s", test.field, test.raw)
		}
	}
}
