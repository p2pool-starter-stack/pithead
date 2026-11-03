package status

import (
	"bytes"
	"os"
	"path/filepath"
	"runtime"
	"testing"
)

func TestEchoEscapesBashUnicodeBytes(t *testing.T) {
	t.Setenv("LC_ALL", "C.UTF-8")
	for _, test := range []struct {
		input string
		want  []byte
	}{
		{`\u0000`, []byte{0x00}},
		{`\u007f`, []byte{0x7f}},
		{`\u0080`, []byte{0xc2, 0x80}},
		{`\u07FF`, []byte{0xdf, 0xbf}},
		{`\u0800`, []byte{0xe0, 0xa0, 0x80}},
		{`\uD7FF`, []byte{0xed, 0x9f, 0xbf}},
		{`\uD800`, []byte{0xed, 0xa0, 0x80}},
		{`\uDFFF`, []byte{0xed, 0xbf, 0xbf}},
		{`\uE000`, []byte{0xee, 0x80, 0x80}},
		{`\uFFFF`, []byte{0xef, 0xbf, 0xbf}},
		{`\U00010000`, []byte{0xf0, 0x90, 0x80, 0x80}},
		{`\U0010FFFF`, []byte{0xf4, 0x8f, 0xbf, 0xbf}},
		{`\U00110000`, []byte{0xf4, 0x90, 0x80, 0x80}},
		{`\U001FFFFF`, []byte{0xf7, 0xbf, 0xbf, 0xbf}},
		{`\U00200000`, []byte{0xf8, 0x88, 0x80, 0x80, 0x80}},
		{`\U003FFFFF`, []byte{0xf8, 0x8f, 0xbf, 0xbf, 0xbf}},
		{`\U04000000`, []byte{0xfc, 0x84, 0x80, 0x80, 0x80, 0x80}},
		{`\U7FFFFFFF`, []byte{0xfd, 0xbf, 0xbf, 0xbf, 0xbf, 0xbf}},
		{`before\U80000000after`, []byte("beforeafter")},
		{`before\UFFFFFFFFafter`, []byte("beforeafter")},
		{`\u`, []byte(`\u`)},
		{`\U`, []byte(`\U`)},
		{`\uZ`, []byte(`\uZ`)},
		{`\Uxyz`, []byte(`\Uxyz`)},
		{`\u1z`, []byte{0x01, 'z'}},
	} {
		if got := []byte(echoEscapes(test.input)); !bytes.Equal(got, test.want) {
			t.Errorf("echoEscapes(%q) = %x, want %x", test.input, got, test.want)
		}
	}
}

func TestEchoEscapesBashCLocale(t *testing.T) {
	t.Setenv("LC_ALL", "C")
	for _, test := range []struct {
		input string
		want  []byte
	}{
		{`\u0041`, []byte("A")},
		{`\u0080`, []byte(`\u0080`)},
		{`\uD800`, []byte(`\uD800`)},
		{`\U00110000`, []byte(`\U00110000`)},
		{`before\U80000000after`, []byte("beforeafter")},
	} {
		if got := []byte(echoEscapes(test.input)); !bytes.Equal(got, test.want) {
			t.Errorf("echoEscapes(%q) = %x, want %x", test.input, got, test.want)
		}
	}
}

func TestLocaleSupported(t *testing.T) {
	for _, locale := range []string{"", "C", "POSIX"} {
		t.Run(locale, func(t *testing.T) {
			t.Setenv("LC_ALL", locale)
			t.Setenv("LC_CTYPE", "")
			t.Setenv("LANG", "")
			t.Setenv("PATH", t.TempDir())
			if !LocaleSupported() {
				t.Fatal("C locale rejected")
			}
		})
	}

	for _, test := range []struct {
		name    string
		output  string
		stderr  string
		status  int
		allowed bool
	}{
		{"utf8-hyphen", "UTF-8\n", "", 0, true},
		{"utf8-compact", "utf8\n", "", 0, true},
		{"latin1", "ISO8859-1\n", "", 0, false},
		{"provider-warning", "UTF-8\n", "warning\n", 0, false},
		{"provider-error", "UTF-8\n", "", 1, false},
	} {
		t.Run(test.name, func(t *testing.T) {
			dir := t.TempDir()
			provider := filepath.Join(dir, "locale")
			script := "#!/bin/sh\nprintf '%s' '" + test.output + "'\nprintf '%s' '" + test.stderr + "' >&2\nexit " + string(rune('0'+test.status)) + "\n"
			if runtime.GOOS == "windows" {
				t.Skip("shell provider unavailable")
			}
			if err := os.WriteFile(provider, []byte(script), 0700); err != nil {
				t.Fatal(err)
			}
			t.Setenv("LC_ALL", "fixture")
			t.Setenv("PATH", dir)
			if got := LocaleSupported(); got != test.allowed {
				t.Fatalf("LocaleSupported() = %v, want %v", got, test.allowed)
			}
		})
	}
}
