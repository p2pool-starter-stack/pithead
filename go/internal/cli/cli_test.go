package cli

import (
	"bytes"
	"errors"
	"reflect"
	"strings"
	"syscall"
	"testing"
)

func TestNativeCommand(t *testing.T) {
	for _, tc := range []struct {
		args []string
		want string
	}{
		{nil, ""},
		{[]string{"", "--help"}, ""},
		{[]string{"help"}, "help"},
		{[]string{"--help", "status"}, "help"},
		{[]string{"-h", "ignored"}, "help"},
		{[]string{"help", "ignored"}, "help"},
		{[]string{"help", "version"}, ""},
		{[]string{"help", "version help"}, ""},
		{[]string{"version", "status"}, ""},
		{[]string{"version", "--help"}, "help"},
		{[]string{"-V", "status"}, "version"},
		{[]string{"--version", "ignored"}, "version"},
		{[]string{"upgrade", "--help"}, "help"},
		{[]string{"unknown", "--help"}, "help"},
		{[]string{"logs", "--help"}, ""},
		{[]string{"logs", "-h"}, ""},
		{[]string{"status", "doctor"}, ""},
		{[]string{"status"}, "status"},
		{[]string{"doctor", "--json"}, "doctor-json"},
		{[]string{"doctor"}, ""},
		{[]string{"doctor", "--json", "extra"}, ""},
		{[]string{"doctor", "--json", "--json"}, ""},
		{[]string{"doctor", "--json", "--help"}, "help"},
		{[]string{"tor-recover", "apply"}, ""},
		{[]string{"tor-recover", "apply", "-h"}, "help"},
		{[]string{"status", "--json"}, ""},
		{[]string{"frobnicate"}, ""},
	} {
		t.Run(strings.Join(tc.args, " "), func(t *testing.T) {
			if got := nativeCommand(tc.args); got != tc.want {
				t.Fatalf("nativeCommand(%q) = %q, want %q", tc.args, got, tc.want)
			}
		})
	}
}

func TestFallbackEnv(t *testing.T) {
	env := []string{"PATH=/bin", "PITHEAD_IMPL=go", "PITHEAD_IMPL=python", "PITHEAD_GO_REFERENCE=./pithead", "PITHEAD_CONFIG_FILE=candidate", "PITHEAD_ENV_FILE=preview"}
	want := []string{"PATH=/bin", "PITHEAD_CONFIG_FILE=candidate", "PITHEAD_ENV_FILE=preview", "PITHEAD_IMPL=bash"}
	if got := fallbackEnv(env); !reflect.DeepEqual(got, want) {
		t.Fatalf("environment = %q, want %q", got, want)
	}
	if env[1] != "PITHEAD_IMPL=go" {
		t.Fatal("input environment was modified")
	}
}

func TestRunHelp(t *testing.T) {
	var output bytes.Buffer
	if err := Run("./pithead", []string{"upgrade", "--help"}, &output); err != nil {
		t.Fatal(err)
	}
	if !bytes.HasPrefix(output.Bytes(), []byte("Usage: ./pithead <command> [options]\n")) {
		t.Fatalf("unexpected usage: %.80s", output.Bytes())
	}
}

func TestHelpBrokenPipe(t *testing.T) {
	err := Run("./pithead", []string{"help"}, brokenPipeWriter{})
	var exitError *ExitError
	if !errors.As(err, &exitError) || exitError.Code != 141 {
		t.Fatalf("error = %v, want exit 141", err)
	}
	if !strings.Contains(exitError.Message, "bash -x ./pithead <command>") {
		t.Fatalf("error = %s", exitError.Message)
	}
}

type brokenPipeWriter struct{}

func (brokenPipeWriter) Write([]byte) (int, error) {
	return 0, syscall.EPIPE
}
