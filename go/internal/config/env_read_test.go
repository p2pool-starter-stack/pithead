package config

import "testing"

func TestDecodeEnvValue(t *testing.T) {
	for _, test := range []struct{ value, key, want, reason string }{
		{`plain=value`, "KEY", `plain=value`, ""},
		{`"line\ncarriage\rtab\tquote\"slash\\unknown\qcash$$escaped\$$tail\"`, "KEY", "line\ncarriage\rtab\tquote\"slash\\unknownqcash$escaped$$tail\\", ""},
		{`""`, "KEY", "", ""},
		{`"unterminated`, "KEY", `"unterminated`, ""},
		{`"bad\npath"`, "DATA_DIR", "bad\npath", directoryLineBreakReason},
		{`bad
path`, "DATA_DIR", "bad\npath", directoryLineBreakReason},
	} {
		got, reason := DecodeEnvValue(test.value, test.key)
		if got != test.want || reason != test.reason {
			t.Fatalf("DecodeEnvValue(%q, %q) = %q, %q; want %q, %q", test.value, test.key, got, reason, test.want, test.reason)
		}
	}
}

func TestEnvGetFile(t *testing.T) {
	raw := []byte("A=first=rest\nB=\"two\\nlines\"\nA=second\nLOWER=ok\nLAST=end")
	for _, test := range []struct {
		key, want, reason string
		ok                bool
	}{
		{"A", "first=rest", "", true},
		{"B", "two\nlines", "", true},
		{"LOWER", "ok", "", true},
		{"LAST", "end", "", true},
		{"MISSING", "", "", true},
		{"A.*", "", "", false},
		{"9BAD", "", "", false},
	} {
		got, reason, ok := EnvGetFile(raw, test.key)
		if got != test.want || reason != test.reason || ok != test.ok {
			t.Fatalf("EnvGetFile(%q) = %q, %q, %v; want %q, %q, %v", test.key, got, reason, ok, test.want, test.reason, test.ok)
		}
	}
	if _, _, ok := EnvGetFile([]byte("A=one\x00B=two"), "A"); ok {
		t.Fatal("NUL file was accepted")
	}
}
