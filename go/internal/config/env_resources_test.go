package config

import (
	"errors"
	"testing"
)

func TestPrepThreads(t *testing.T) {
	tests := map[string]string{
		"-9223372036854775806": "4",
		"-10":                  "4",
		"0":                    "4",
		"6":                    "4",
		"7":                    "5",
		"9":                    "7",
		"10":                   "8",
		"9223372036854775807":  "8",
	}
	for input, want := range tests {
		got, err := PrepThreads(input)
		if err != nil || got != want {
			t.Errorf("PrepThreads(%q) = %q, %v; want %q, nil", input, got, err, want)
		}
	}
}

func TestPrepThreadsUnsupported(t *testing.T) {
	for _, input := range []string{
		"", "00", "01", "+7", "-0", "1+2", "eight",
		"-9223372036854775808", "-9223372036854775807", "9223372036854775808",
	} {
		got, err := PrepThreads(input)
		if got != "" || !errors.Is(err, ErrUnsupportedResources) {
			t.Errorf("PrepThreads(%q) = %q, %v; want empty, unsupported", input, got, err)
		}
	}
}

func TestOutPeersValid(t *testing.T) {
	tests := map[string]bool{
		"": false, "7": false, "8": true, "0008": true, "1024": true,
		"1025": false, "-1": false, "+8": false, "eight": false, "８": false,
	}
	for input, want := range tests {
		got, err := OutPeersValid(input)
		if err != nil || got != want {
			t.Errorf("OutPeersValid(%q) = %t, %v; want %t, nil", input, got, err, want)
		}
	}
	for _, input := range []string{"9223372036854775808", "999999999999999999999999999999"} {
		got, err := OutPeersValid(input)
		if got || !errors.Is(err, ErrUnsupportedResources) {
			t.Errorf("OutPeersValid(%q) = %t, %v; want false, unsupported", input, got, err)
		}
	}
}
