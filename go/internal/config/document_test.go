package config

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestDocumentValidationOrder(t *testing.T) {
	tests := []struct {
		name    string
		raw     string
		request bool
		want    string
	}{
		{"top duplicate", `{"monero":{},"monero":{}}`, false, `duplicate key "monero" at the top level (path monero)`},
		{"nested duplicate", `{"dashboard":{"auth":{"password":"first","password":"last"}}}`, false, `duplicate key "password" at dashboard.auth (path dashboard.auth.password)`},
		{"array duplicate", `{"workers":{"list":[{"token":"first","token":"last"}]}}`, false, `duplicate key "token" at workers.list[0] (path workers.list[0].token)`},
		{"decoded duplicate", `{"monero":{},"\u006donero":{}}`, false, `duplicate key "monero" at the top level (path monero)`},
		{"nested before later sibling", `{"a":{"x":0,"x":1},"a":2}`, false, `duplicate key "x" at a (path a.x)`},
		{"sibling before nested value", `{"a":0,"a":{"x":0,"x":1}}`, false, `duplicate key "a" at the top level (path a)`},
		{"placeholder", `{"dashboard":{"host":"PASTE_secret"}}`, false, `placeholder value at dashboard.host`},
		{"root placeholder", `"YOUR_secret"`, false, `placeholder value at the top level`},
		{"request config", `{"actor":"YOUR_user","config":{"dashboard":{"host":"paste_secret"}}}`, true, `placeholder value at dashboard.host`},
		{"request ignores actor", `{"actor":"YOUR_user","config":{}}`, true, ""},
		{"request absent config", `{"actor":"YOUR_user"}`, true, ""},
		{"request nonobject", `"YOUR_secret"`, true, `placeholder value at the top level`},
		{"unicode uppercase", `{"a":"pa\u017fte_secret"}`, false, `placeholder value at a`},
		{"ligature uppercase", `{"a":"pa\ufb05e_secret"}`, false, `placeholder value at a`},
		{"quoted nonfinite names", `{"nan":"NaN","infinity":"-Infinity"}`, false, ""},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			document, err := ParseDocument([]byte(test.raw))
			if err != nil {
				t.Fatal(err)
			}
			if got := document.ValidationError(test.request); got != test.want {
				t.Fatalf("ValidationError() = %q, want %q", got, test.want)
			}
		})
	}
}

func TestDocumentPathsMatchPythonFormatting(t *testing.T) {
	tests := []struct {
		raw  string
		want string
	}{
		{`{"caf\u00e9":"YOUR_x"}`, `placeholder value at caf\u00e9`},
		{`{"bad\nkey":"YOUR_x"}`, `placeholder value at bad\nkey`},
		{`{"a\"b":"YOUR_x"}`, `placeholder value at a"b`},
		{`{"a\\\"b":"YOUR_x"}`, `placeholder value at a\\"b`},
		{`{"</script>":"YOUR_x"}`, `placeholder value at </script>`},
		{`{"\u0001":"YOUR_x"}`, `placeholder value at \u0001`},
		{`{"\u007f":"YOUR_x"}`, `placeholder value at \u007f`},
		{`{"\ud83d\ude00":"YOUR_x"}`, ""},
	}
	for _, test := range tests {
		document, err := ParseDocument([]byte(test.raw))
		if test.want == "" {
			if !errors.Is(err, ErrUnsupportedDocument) {
				t.Fatalf("ParseDocument(%q) error = %v", test.raw, err)
			}
			continue
		}
		if err != nil {
			t.Fatal(err)
		}
		got := document.ValidationError(false)
		if got != test.want {
			t.Fatalf("ValidationError() = %q, want %q", got, test.want)
		}
		if strings.Contains(got, "YOUR_x") || strings.Contains(got, "\n") && strings.ContainsRune(got, '\n') {
			t.Fatalf("unsafe diagnostic %q", got)
		}
	}
}

func TestParseDocumentRejectsSyntaxBeforeDuplicates(t *testing.T) {
	for _, raw := range []string{
		`{"a":0,"a":1`,
		`{"a":0,"a":1} {}`,
		`{"a":0,"a":1,}`,
	} {
		document, err := ParseDocument([]byte(raw))
		if err == nil || errors.Is(err, ErrUnsupportedDocument) || document != nil {
			t.Fatalf("ParseDocument(%q) = %#v, %v", raw, document, err)
		}
	}
}

func TestParseDocumentUnsupportedCompatibilityInputs(t *testing.T) {
	deep := strings.Repeat("[", 129) + "0" + strings.Repeat("]", 129)
	hugeInteger := strings.Repeat("9", 4097)
	for _, raw := range [][]byte{
		{0xff},
		[]byte(`"\ud800"`),
		[]byte(`"\ud83d\ude00"`),
		[]byte(`NaN`),
		[]byte(`-Infinity`),
		[]byte(deep),
		[]byte(hugeInteger),
		[]byte("-" + hugeInteger),
	} {
		document, err := ParseDocument(raw)
		if document != nil || !errors.Is(err, ErrUnsupportedDocument) {
			t.Fatalf("ParseDocument(%q) = %#v, %v", raw, document, err)
		}
	}
}

func TestParseDocumentKeepsJSONNumbers(t *testing.T) {
	document, err := ParseDocument([]byte(`123456789012345678901234567890`))
	if err != nil {
		t.Fatal(err)
	}
	number, ok := document.root.value.(json.Number)
	if !ok {
		t.Fatalf("number type = %T", document.root.value)
	}
	if got := number.String(); got != "123456789012345678901234567890" {
		t.Fatalf("number = %q", got)
	}
}

func TestValidateDocumentFile(t *testing.T) {
	directory := t.TempDir()
	valid := filepath.Join(directory, "valid.json")
	malformed := filepath.Join(directory, "malformed.json")
	unsupported := filepath.Join(directory, "unsupported.json")
	for path, content := range map[string][]byte{
		valid:       []byte(`{"config":{"host":"YOUR_secret"}}`),
		malformed:   []byte(`{"secret":"do-not-print"`),
		unsupported: []byte{0xff},
	} {
		if err := os.WriteFile(path, content, 0o600); err != nil {
			t.Fatal(err)
		}
	}

	tests := []struct {
		name   string
		path   string
		want   string
		badErr bool
	}{
		{"valid", valid, "placeholder value at host", false},
		{"malformed", malformed, "not valid JSON", false},
		{"missing", filepath.Join(directory, "missing.json"), "could not read config document", false},
		{"directory", directory, "could not read config document", false},
		{"unsupported content", unsupported, "", true},
		{"nul path", "bad\x00path", "", true},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			got, err := ValidateDocumentFile(test.path, true)
			if got != test.want || errors.Is(err, ErrUnsupportedDocument) != test.badErr {
				t.Fatalf("ValidateDocumentFile() = %q, %v", got, err)
			}
			if strings.Contains(got, "do-not-print") || strings.Contains(got, test.path) {
				t.Fatalf("diagnostic exposes input: %q", got)
			}
		})
	}
}
