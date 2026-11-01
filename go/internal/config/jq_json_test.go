package config

import (
	"encoding/json"
	"errors"
	"testing"
)

func TestPrettyJQ(t *testing.T) {
	root := node{object: []member{
		{key: "first", value: node{array: []node{
			{value: json.Number("1")},
			{object: []member{{key: "enabled", value: node{value: true}}}},
		}}},
		{key: "empty-object", value: node{object: []member{}}},
		{key: "empty-array", value: node{array: []node{}}},
		{key: "nothing", value: node{}},
	}}
	want := "{\n" +
		"  \"first\": [\n" +
		"    1,\n" +
		"    {\n" +
		"      \"enabled\": true\n" +
		"    }\n" +
		"  ],\n" +
		"  \"empty-object\": {},\n" +
		"  \"empty-array\": [],\n" +
		"  \"nothing\": null\n" +
		"}\n"

	got, err := prettyJQ(root)
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != want {
		t.Fatalf("prettyJQ() = %q, want %q", got, want)
	}
}

func TestPrettyJQStringEscaping(t *testing.T) {
	root := node{object: []member{{
		key:   "\x00\b\t\n\f\r\x1f\x7f©\u2028\u2029\"\\",
		value: node{value: "</script>\x00\b\t\n\f\r\x1f\x7f©\u2028\u2029\"\\"},
	}}}
	want := "{\n" +
		`  "\u0000\b\t\n\f\r\u001f\u007f©  \"\\": "</script>\u0000\b\t\n\f\r\u001f\u007f©  \"\\"` + "\n}\n"

	got, err := prettyJQ(root)
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != want {
		t.Fatalf("prettyJQ() = %q, want %q", got, want)
	}
}

func TestRawJQPreservesStringBytes(t *testing.T) {
	want := []byte{'x', '\n', '\n', 0, '\n'}
	got, err := rawJQ(node{value: "x\n\n\x00"})
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != string(want) {
		t.Fatalf("rawJQ() = %v, want %v", got, want)
	}

	nonString, err := rawJQ(node{value: false})
	if err != nil {
		t.Fatal(err)
	}
	if string(nonString) != "false\n" {
		t.Fatalf("rawJQ(false) = %q", nonString)
	}
}

func TestJQIntegerLimits(t *testing.T) {
	for _, value := range []string{"0", "9007199254740991", "-9007199254740991"} {
		got, err := prettyJQ(node{value: json.Number(value)})
		if err != nil {
			t.Fatalf("prettyJQ(%q): %v", value, err)
		}
		if string(got) != value+"\n" {
			t.Fatalf("prettyJQ(%q) = %q", value, got)
		}
	}
}

func TestJQRejectsUnsupportedNodesWithoutOutput(t *testing.T) {
	tests := []struct {
		name string
		root node
	}{
		{"negative zero", node{value: json.Number("-0")}},
		{"decimal", node{value: json.Number("1.0")}},
		{"exponent", node{value: json.Number("1e0")}},
		{"leading zero", node{value: json.Number("01")}},
		{"positive overflow", node{value: json.Number("9007199254740992")}},
		{"negative overflow", node{value: json.Number("-9007199254740992")}},
		{"non-number scalar", node{value: 1}},
		{"invalid UTF-8 string", node{value: string([]byte{0xff})}},
		{"mixed compound", node{object: []member{}, array: []node{}}},
		{"nested failure", node{array: []node{{value: true}, {value: json.Number("1.5")}}}},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			got, err := prettyJQ(test.root)
			if got != nil || !errors.Is(err, ErrUnsupportedDefaults) {
				t.Fatalf("prettyJQ() = %q, %v", got, err)
			}
		})
	}
}
