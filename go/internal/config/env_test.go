package config

import (
	"errors"
	"strings"
	"testing"
)

func TestRenderEnvPreservesOrderAndQuotesLikeDotenvRenderValue(t *testing.T) {
	pairs := []EnvPair{
		{Key: "PLAIN", Value: "alpha beta#gamma"},
		{Key: "EMPTY", Value: ""},
		{Key: "SPECIAL", Value: "a\\b\"c$d'e\n\r\t"},
		{Key: "LEADING", Value: " value"},
		{Key: "COMMENT", Value: "value #comment"},
		{Key: "UNICODE", Value: "café"},
	}
	want := "PLAIN=alpha beta#gamma\n" +
		"EMPTY=\n" +
		"SPECIAL=\"a\\\\b\\\"c$$d'e\\n\\r\\t\"\n" +
		"LEADING=\" value\"\n" +
		"COMMENT=\"value #comment\"\n" +
		"UNICODE=café\n"
	got, err := RenderEnv(pairs)
	if err != nil || string(got) != want {
		t.Fatalf("RenderEnv() = %q, %v; want %q, nil", got, err, want)
	}
}

func TestRenderEnvASCIIWhitespaceCases(t *testing.T) {
	tests := []struct {
		name  string
		value string
		want  string
	}{
		{"internal space", "a b", "a b"},
		{"internal form feed", "a\fb", "a\fb"},
		{"leading form feed", "\fa", "\"\fa\""},
		{"trailing vertical tab", "a\v", "\"a\v\""},
		{"form feed before comment", "a\f#b", "\"a\f#b\""},
		{"internal tab", "a\tb", "\"a\\tb\""},
		{"internal carriage return", "a\rb", "\"a\\rb\""},
		{"internal newline", "a\nb", "\"a\\nb\""},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			got, err := RenderEnv([]EnvPair{{Key: "VALUE", Value: test.value}})
			want := "VALUE=" + test.want + "\n"
			if err != nil || string(got) != want {
				t.Fatalf("RenderEnv() = %q, %v; want %q, nil", got, err, want)
			}
		})
	}
}

func TestRenderEnvRejectsUnsupportedInputWithoutPartialOutput(t *testing.T) {
	secret := "operator-secret"
	tests := []struct {
		name  string
		pairs []EnvPair
	}{
		{"empty", nil},
		{"empty key", []EnvPair{{Key: "", Value: secret}}},
		{"lowercase key", []EnvPair{{Key: "bad", Value: secret}}},
		{"digit first", []EnvPair{{Key: "1BAD", Value: secret}}},
		{"punctuation key", []EnvPair{{Key: "BAD-KEY", Value: secret}}},
		{"duplicate", []EnvPair{{Key: "GOOD", Value: secret}, {Key: "GOOD", Value: "other"}}},
		{"invalid UTF-8", []EnvPair{{Key: "GOOD", Value: secret}, {Key: "BAD", Value: string([]byte{0xff})}}},
		{"NUL", []EnvPair{{Key: "GOOD", Value: secret}, {Key: "BAD", Value: "a\x00b"}}},
		{"Unicode whitespace", []EnvPair{{Key: "GOOD", Value: secret}, {Key: "BAD", Value: "a\u00a0b"}}},
		{"Unicode control", []EnvPair{{Key: "GOOD", Value: secret}, {Key: "BAD", Value: "a\u0085b"}}},
		{"Unicode format", []EnvPair{{Key: "GOOD", Value: secret}, {Key: "BAD", Value: "a\u200eb"}}},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			got, err := RenderEnv(test.pairs)
			if got != nil || !errors.Is(err, ErrUnsupportedEnv) {
				t.Fatalf("RenderEnv() = %q, %v; want nil, unsupported", got, err)
			}
			if strings.Contains(err.Error(), secret) {
				t.Fatalf("error exposes input: %q", err)
			}
		})
	}
}
