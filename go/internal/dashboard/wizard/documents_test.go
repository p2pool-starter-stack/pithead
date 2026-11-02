package wizard

import (
	"bytes"
	"encoding/json"
	"errors"
	"testing"
)

func documentValue(value *ConfigValue) *DocumentNode {
	return &DocumentNode{Kind: "value", Value: value}
}

func documentObject(fields ...DocumentField) *DocumentNode {
	return &DocumentNode{Kind: "object", Fields: fields}
}

func documentField(key string, value *DocumentNode) DocumentField {
	return DocumentField{Key: opString(key), Value: value}
}

func documentJSONField(keyJSON string, value *DocumentNode) DocumentField {
	return DocumentField{KeyJSON: opString(keyJSON), Value: value}
}

func TestDecodeDocumentPreservesOrderAndTaggedValues(t *testing.T) {
	nan := &ConfigValue{Kind: "float", Text: "nan", Identity: 17}
	node := documentObject(
		documentField("z", documentValue(nan)),
		documentField("a", &DocumentNode{Kind: "array", Items: []*DocumentNode{
			documentValue(opInt("9007199254740993")),
			documentValue(opString(string([]byte{0xed, 0xa0, 0x80}))),
		}}),
	)
	result, err := handleDocumentRequest(DocumentRequest{Operation: "decode", Node: node})
	if err != nil || result.Fault != nil {
		t.Fatalf("decode failed: result=%+v err=%v", result, err)
	}
	if len(result.Value.Fields) != 2 || result.Value.Fields[0].Key != "z" || result.Value.Fields[1].Key != "a" {
		t.Fatalf("field order changed: %+v", result.Value.Fields)
	}
	if result.Value.Fields[0].Value.Text != "nan" || result.Value.Fields[0].Value.Identity != 17 {
		t.Fatalf("NaN identity changed: %+v", result.Value.Fields[0].Value)
	}
	if result.Value.Fields[1].Value.Items[1].Text != string([]byte{0xed, 0xa0, 0x80}) {
		t.Fatalf("lone surrogate changed: %q", result.Value.Fields[1].Value.Items[1].Text)
	}
}

func TestDecodeDocumentPlansNestedPassthroughAliases(t *testing.T) {
	rootValue := documentValue(opDict(opField("kept", opList())))
	rootValue.Identity = 11
	nestedValue := documentValue(opString("kept"))
	nestedValue.Identity = 12
	node := &DocumentNode{Kind: "array", Items: []*DocumentNode{
		rootValue,
		documentObject(documentField("inner", nestedValue)),
	}}
	result, err := handleDocumentRequest(DocumentRequest{Operation: "decode", Node: node})
	if err != nil || result.Value.Kind != "list" || len(result.Aliases) != 2 {
		t.Fatalf("passthrough result: %+v err=%v", result, err)
	}
	if len(result.Aliases[0].Path) != 1 || result.Aliases[0].Path[0].Kind != "int" || result.Aliases[0].Path[0].Text != "0" || result.Aliases[0].Identity != 11 {
		t.Fatalf("first alias: %+v", result.Aliases[0])
	}
	if len(result.Aliases[1].Path) != 2 || result.Aliases[1].Path[0].Text != "1" || result.Aliases[1].Path[1].Text != "inner" || result.Aliases[1].Identity != 12 {
		t.Fatalf("second alias: %+v", result.Aliases[1])
	}
}

func TestDecodeDocumentRootAliasUsesEmptyPath(t *testing.T) {
	node := documentValue(opString("kept"))
	node.Identity = 21
	result, err := handleDocumentRequest(DocumentRequest{Operation: "decode", Node: node})
	if err != nil || len(result.Aliases) != 1 || result.Aliases[0].Identity != 21 || result.Aliases[0].Path == nil || len(result.Aliases[0].Path) != 0 {
		t.Fatalf("root alias: %+v err=%v", result, err)
	}
	raw, err := json.Marshal(result)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Contains(raw, []byte(`"path":[]`)) {
		t.Fatalf("root alias wire path is not empty: %s", raw)
	}
}

func TestDecodeDocumentRejectsDuplicateBeforeSecondValue(t *testing.T) {
	node := documentObject(
		documentField("repeat", documentValue(opInt("1"))),
		documentField("repeat", &DocumentNode{Kind: "invalid"}),
	)
	result, err := handleDocumentRequest(DocumentRequest{Operation: "decode", Node: node})
	if err != nil {
		t.Fatal(err)
	}
	if result.Fault == nil || result.Fault.Kind != "ConfigDocumentError" {
		t.Fatalf("missing duplicate fault: %+v", result)
	}
	if result.Fault.Diagnostic.Text != `duplicate key "repeat" at the top level (path repeat)` {
		t.Fatalf("unexpected diagnostic: %q", result.Fault.Diagnostic.Text)
	}
}

func TestDecodeAndPlaceholderHonorStartingPath(t *testing.T) {
	duplicate := documentObject(
		documentField("repeat", documentValue(opInt("1"))),
		documentField("repeat", documentValue(opInt("2"))),
	)
	result, err := handleDocumentRequest(DocumentRequest{Operation: "decode", Node: duplicate, Path: opString("base[2]")})
	if err != nil || result.Fault == nil || result.Fault.Path.Text != "base[2]" {
		t.Fatalf("decode path result: %+v err=%v", result, err)
	}
	placeholder := documentObject(documentField("token", documentValue(opString("YOUR_SECRET"))))
	result, err = handleDocumentRequest(DocumentRequest{Operation: "placeholders", Node: placeholder, Path: opString("base[2]")})
	if err != nil || result.Fault == nil || result.Fault.Path.Text != "base[2].token" {
		t.Fatalf("placeholder path result: %+v err=%v", result, err)
	}
}

func TestDocumentPathsMatchPythonEscaping(t *testing.T) {
	surrogate := string([]byte{0xed, 0xa0, 0x80})
	tests := map[string]string{
		`a"b`:        `root.a"b`,
		`a\b`:        `root.a\\b`,
		surrogate:    `root.\ud800`,
		"\U0001f600": `root.\ud83d\ude00`,
		"a\nb":       `root.a\nb`,
	}
	for key, expected := range tests {
		result, err := handleDocumentRequest(DocumentRequest{Operation: "path", Path: opString("root"), Key: opString(key)})
		if err != nil {
			t.Fatal(err)
		}
		if result.Value.Text != expected {
			t.Errorf("path(%q) = %q, want %q", key, result.Value.Text, expected)
		}
	}
}

func TestDocumentPathsUsePythonDumpForNonStringKeys(t *testing.T) {
	tests := map[string]string{
		"1":          "root.",
		"12":         "root.",
		"true":       "root.ru",
		"null":       "root.ul",
		"[1, 2]":     "root.1, 2",
		`["a", "b"]`: `root."a", "b"`,
	}
	for dumped, expected := range tests {
		result, err := handleDocumentRequest(DocumentRequest{Operation: "path", Path: opString("root"), KeyJSON: opString(dumped)})
		if err != nil || result.Value.Text != expected {
			t.Errorf("path(%s) = %+v, err=%v, want %q", dumped, result, err, expected)
		}
	}
	diagnostic, err := handleDocumentRequest(DocumentRequest{Operation: "diagnostic", Path: opString("root"), KeyJSON: opString("12")})
	if err != nil || diagnostic.Value.Text != "duplicate key 12 at root (path root.)" {
		t.Fatalf("non-string diagnostic: %+v err=%v", diagnostic, err)
	}
}

func TestDocumentDiagnosticsMatchPython(t *testing.T) {
	placeholder, err := handleDocumentRequest(DocumentRequest{Operation: "diagnostic", Path: opString("")})
	if err != nil || placeholder.Value.Text != "placeholder value at the top level" {
		t.Fatalf("placeholder diagnostic: %+v err=%v", placeholder, err)
	}
	duplicate, err := handleDocumentRequest(DocumentRequest{Operation: "diagnostic", Path: opString("root"), Key: opString(`a"b`)})
	if err != nil || duplicate.Value.Text != `duplicate key "a\"b" at root (path root.a"b)` {
		t.Fatalf("duplicate diagnostic: %+v err=%v", duplicate, err)
	}
}

func TestPlaceholderTraversalUsesPythonUpperAndDepthFirstPath(t *testing.T) {
	node := documentObject(documentField("outer", &DocumentNode{Kind: "array", Items: []*DocumentNode{
		documentValue(opString("safe")),
		documentObject(documentField("inner", documentValue(opString("PA\ufb05E_secret")))),
	}}))
	result, err := handleDocumentRequest(DocumentRequest{Operation: "placeholders", Node: node})
	if err != nil {
		t.Fatal(err)
	}
	if result.Fault == nil || result.Fault.Path.Text != "outer[1].inner" {
		t.Fatalf("unexpected placeholder result: %+v", result)
	}
	if result.Fault.Key != nil || result.Fault.Diagnostic.Text != "placeholder value at outer[1].inner" {
		t.Fatalf("unexpected placeholder fault: %+v", result.Fault)
	}
}

func TestPlaceholderTraversalPreservesNonStringFieldPaths(t *testing.T) {
	node := documentObject(
		documentJSONField("1", documentValue(opString("safe"))),
		documentJSONField("[1, 2]", documentValue(opString("YOUR_SECRET"))),
	)
	result, err := handleDocumentRequest(DocumentRequest{Operation: "placeholders", Node: node, Path: opString("root")})
	if err != nil || result.Fault == nil || result.Fault.Path.Text != "root.1, 2" {
		t.Fatalf("non-string placeholder result: %+v err=%v", result, err)
	}
}

func TestHostDocumentFaultAndValues(t *testing.T) {
	tests := []struct {
		name    string
		reason  *ConfigValue
		message string
	}{
		{"text", opString(""), ""},
		{"nonstr", opInt("1"), "Invalid host configuration"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			node := documentObject(documentField("_config_document_error", documentValue(test.reason)))
			result, err := handleDocumentRequest(DocumentRequest{Operation: "host", Node: node})
			if err != nil {
				t.Fatal(err)
			}
			if result.Fault == nil || result.Fault.Kind != "HostConfigError" || result.Fault.Diagnostic.Text != test.message {
				t.Fatalf("unexpected host result: %+v", result)
			}
		})
	}
	scalar, err := handleDocumentRequest(DocumentRequest{Operation: "host", Node: documentValue(opString("ok"))})
	if err != nil || scalar.Value.Text != "ok" || scalar.Fault != nil {
		t.Fatalf("unexpected scalar host result: %+v err=%v", scalar, err)
	}
}

func TestRunDocumentsJSONLinesAndWriteError(t *testing.T) {
	requests := []DocumentRequest{
		{Operation: "path", Path: opString(""), Key: opString("key")},
		{Operation: "unknown"},
	}
	var input bytes.Buffer
	for _, request := range requests {
		if err := json.NewEncoder(&input).Encode(request); err != nil {
			t.Fatal(err)
		}
	}
	var output bytes.Buffer
	if err := RunDocuments(&input, &output); err != nil {
		t.Fatal(err)
	}
	decoder := json.NewDecoder(&output)
	responses := make([]Response, 2)
	for index := range responses {
		var response Response
		if err := decoder.Decode(&response); err != nil {
			t.Fatal(err)
		}
		responses[index] = response
	}
	if len(responses) != 2 || !responses[0].OK || responses[1].Error == nil || responses[1].Error.Kind != "ValueError" {
		t.Fatalf("unexpected responses: %+v", responses)
	}
	want := errors.New("closed")
	err := RunDocuments(bytes.NewBufferString(`{"operation":"unknown"}`+"\n"), errorDocumentWriter{err: want})
	if !errors.Is(err, want) {
		t.Fatalf("write error = %v, want %v", err, want)
	}
}

type errorDocumentWriter struct{ err error }

func (w errorDocumentWriter) Write([]byte) (int, error) { return 0, w.err }
