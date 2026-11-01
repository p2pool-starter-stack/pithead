package config

import (
	"errors"
	"strings"
	"testing"
)

func TestNormalizeCodeVersion(t *testing.T) {
	for _, test := range []struct {
		input, want string
		valid       bool
		unsupported bool
	}{
		{"2.1.0", "2.1.0", true, false},
		{"02.0001.0-beta+build", "02.0001.0", true, false},
		{"1.2.3+build-beta", "1.2.3", true, false},
		{"1.2", "1.2", false, false},
		{"1.2.12345", "1.2.12345", false, false},
		{"1.2.3\n", "", false, true},
		{"1.2.é", "", false, true},
	} {
		got, valid, err := NormalizeCodeVersion(test.input)
		if got != test.want || valid != test.valid || errors.Is(err, ErrUnsupportedVersion) != test.unsupported {
			t.Fatalf("NormalizeCodeVersion(%q) = %q, %t, %v", test.input, got, valid, err)
		}
	}
}

func TestPlanConfigVersion(t *testing.T) {
	for _, test := range []struct {
		name, raw, version string
		want               VersionPlan
		unsupported        bool
	}{
		{"absent", `{"name":"rig"}`, "2.1.0", VersionPlan{Stamp: "2.0.0"}, false},
		{"null", `{"config_version":null}`, "2.1.0", VersionPlan{Stamp: "2.0.0"}, false},
		{"false", `{"config_version":false}`, "2.1.0", VersionPlan{Stamp: "2.0.0"}, false},
		{"equal", `{"config_version":"02.001.0"}`, "02.001.0", VersionPlan{Stamp: "02.001.0", EqualPresent: true}, false},
		{"newer", `{"config_version":"2.2.0"}`, "2.1.9", VersionPlan{Stamp: "2.2.0", Newer: true}, false},
		{"malformed", `{"config_version":42}`, "2.1.0", VersionPlan{Stamp: "42", Malformed: true}, false},
		{"float plan", `{"config_version":2.1}`, "2.1.0", VersionPlan{Stamp: "2.1", Malformed: true}, false},
		{"object", `{"config_version":{}}`, "2.1.0", VersionPlan{}, true},
		{"duplicate", `{"config_version":"2.0.0","config_version":"2.1.0"}`, "2.1.0", VersionPlan{}, true},
		{"embedded newline", `{"config_version":"2.1.0\nother"}`, "2.1.0", VersionPlan{}, true},
	} {
		t.Run(test.name, func(t *testing.T) {
			got, err := PlanConfigVersion([]byte(test.raw), test.version)
			if got != test.want || errors.Is(err, ErrUnsupportedVersion) != test.unsupported {
				t.Fatalf("PlanConfigVersion() = %#v, %v", got, err)
			}
		})
	}
}

func TestStampConfigVersion(t *testing.T) {
	for _, test := range []struct {
		name, raw, want string
		unsupported     bool
	}{
		{"replace in place", `{"first":"é\u0001","config_version":"2.0.0","last":[1,true]}`, "{\n  \"first\": \"é\\u0001\",\n  \"config_version\": \"2.1.0\",\n  \"last\": [\n    1,\n    true\n  ]\n}\n", false},
		{"append", `{"first":1}`, "{\n  \"first\": 1,\n  \"config_version\": \"2.1.0\"\n}\n", false},
		{"empty", `{}`, "{\n  \"config_version\": \"2.1.0\"\n}\n", false},
		{"float", `{"value":1.5}`, "", true},
		{"duplicate", `{"a":1,"a":2}`, "", true},
		{"readonly passthrough", `{"nested":{"x":"y"},"array":[null,false]}`, "{\n  \"nested\": {\n    \"x\": \"y\"\n  },\n  \"array\": [\n    null,\n    false\n  ],\n  \"config_version\": \"2.1.0\"\n}\n", false},
	} {
		t.Run(test.name, func(t *testing.T) {
			got, err := StampConfigVersion([]byte(test.raw), "2.1.0")
			if string(got) != test.want || errors.Is(err, ErrUnsupportedVersion) != test.unsupported {
				t.Fatalf("StampConfigVersion() = %q, %v", got, err)
			}
			if !test.unsupported && strings.Count(string(got), `"config_version"`) != 1 {
				t.Fatal("stamp was not unique")
			}
		})
	}
}
