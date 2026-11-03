package status

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestDecode(t *testing.T) {
	for _, tc := range []struct{ value, want string }{
		{`literal=value`, `literal=value`},
		{`'single quoted'`, `'single quoted'`},
		{`"dollar$$quote\"slash\\"`, "dollar$quote\"slash\\"},
		{`"line\nreturn\rtab\t"`, "line\nreturn\rtab\t"},
		{`"unknown\q"`, "unknownq"},
		{`"trailing\"`, "trailing\\"},
	} {
		if got := decode(tc.value); got != tc.want {
			t.Errorf("decode(%q) = %q, want %q", tc.value, got, tc.want)
		}
	}
}

func TestGetEnvironment(t *testing.T) {
	dir := t.TempDir()
	data := "VALUE=first=literal\nVALUE=second\nQUOTED=\"double$$dollar\\n\"\nDATA_DIR=\"unsafe\\npath\"\n"
	if err := os.WriteFile(filepath.Join(dir, ".env"), []byte(data), 0600); err != nil {
		t.Fatal(err)
	}
	var stderr bytes.Buffer
	r := Runner{Dir: dir, EnvFile: ".env", Err: &stderr}
	if got := r.get("VALUE"); got != "first=literal" {
		t.Fatalf("first assignment = %q", got)
	}
	if got := r.get("QUOTED"); got != "double$dollar" {
		t.Fatalf("quoted assignment = %q", got)
	}
	if got := r.get("MISSING"); got != "" {
		t.Fatalf("missing assignment = %q", got)
	}
	if got := r.getQuiet("DATA_DIR"); got != "" || stderr.Len() != 0 {
		t.Fatalf("quiet directory rejection = %q, %q", got, stderr.String())
	}
	if got := r.get("DATA_DIR"); got != "" || !strings.Contains(stderr.String(), "Directory values in .env must not contain CR or LF.") {
		t.Fatalf("directory rejection = %q, %q", got, stderr.String())
	}
}

func TestEchoEscapes(t *testing.T) {
	for _, tc := range []struct{ value, want string }{
		{`literal\z`, `literal\z`},
		{`tab\tnewline\n`, "tab\tnewline\n"},
		{`hex\x41octal\0101unicode\u0041`, "hexAoctalAunicodeA"},
		{"stop\\cignored\n", "stop"},
		{`escaped\\c`, `escaped\c`},
		{`\xnohex`, `\xnohex`},
	} {
		if got := echoEscapes(tc.value); got != tc.want {
			t.Errorf("echoEscapes(%q) = %q, want %q", tc.value, got, tc.want)
		}
	}
	var stdout bytes.Buffer
	r := Runner{Out: &stdout}
	r.log(`stop\cignored`)
	if stdout.String() != "[pithead] stop" {
		t.Fatalf("log = %q", stdout.String())
	}
}

func TestRunMissingEnvironment(t *testing.T) {
	var stdout, stderr bytes.Buffer
	r := Runner{Dir: t.TempDir(), Program: "./pithead", EnvFile: ".env", Out: &stdout, Err: &stderr}
	if code := r.Run(); code != 1 || stdout.Len() != 0 || stderr.String() != "[ERROR] No .env found. Run './pithead setup' first.\n" {
		t.Fatalf("code=%d, stdout=%q, stderr=%q", code, stdout.String(), stderr.String())
	}
}
