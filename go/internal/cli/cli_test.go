package cli

import (
	"bytes"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"syscall"
	"testing"
)

func TestNativeCommandRequiresOneExactArgument(t *testing.T) {
	tests := []struct {
		args []string
		want string
	}{
		{[]string{"help"}, "help"},
		{[]string{"-h"}, "help"},
		{[]string{"--help"}, "help"},
		{[]string{"version"}, "version"},
		{[]string{"-V"}, "version"},
		{[]string{"--version"}, "version"},
		{[]string{"status"}, "status"},
		{nil, ""},
		{[]string{"upgrade"}, ""},
		{[]string{"status", "--help"}, ""},
		{[]string{"help", "version"}, ""},
		{[]string{"--unknown"}, ""},
	}
	for _, test := range tests {
		if got := nativeCommand(test.args); got != test.want {
			t.Errorf("nativeCommand(%q) = %q, want %q", test.args, got, test.want)
		}
	}
}

func TestRunRequestsFallbackForEveryOtherInvocation(t *testing.T) {
	for _, args := range [][]string{nil, {"upgrade"}, {"status", "--json"}, {"unknown", "--help"}, {"help", "extra"}, {"--native-cli"}} {
		if err := Run("./pithead", args, &bytes.Buffer{}); !errors.Is(err, ErrFallback) {
			t.Errorf("Run(%q) error = %v, want fallback", args, err)
		}
	}
}

func TestRunHelp(t *testing.T) {
	var output bytes.Buffer
	if err := Run("./pithead", []string{"help"}, &output); err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(output.String(), "Usage: ./pithead <command> [options]\n") {
		t.Fatalf("unexpected usage: %.80s", output.String())
	}
}

func TestHelpBrokenPipe(t *testing.T) {
	err := Run("./pithead", []string{"help"}, brokenPipeWriter{})
	var exitError *ExitError
	if !errors.As(err, &exitError) || exitError.Code != 141 || exitError.Message == "" {
		t.Fatalf("error = %#v, want SIGPIPE exit 141", err)
	}
}

func TestVersionBrokenPipeFallsBack(t *testing.T) {
	if err := Run("./pithead", []string{"version"}, brokenPipeWriter{}); !errors.Is(err, ErrFallback) {
		t.Fatalf("error = %v, want fallback", err)
	}
}

func TestClosedOutputFallsBackBeforeStatusRuns(t *testing.T) {
	output, err := os.CreateTemp(t.TempDir(), "closed-output")
	if err != nil {
		t.Fatal(err)
	}
	if err := output.Close(); err != nil {
		t.Fatal(err)
	}
	if err := Run("./pithead", []string{"status"}, output); !errors.Is(err, ErrFallback) {
		t.Fatalf("error = %v, want fallback", err)
	}
}

func TestHelpOtherWriteFailureFallsBack(t *testing.T) {
	if err := Run("./pithead", []string{"help"}, failedWriter{}); !errors.Is(err, ErrFallback) {
		t.Fatalf("error = %v, want fallback", err)
	}
}

func TestStatusFallsBackWhenAnyPrerequisiteIsMissing(t *testing.T) {
	dir := t.TempDir()
	for _, missing := range []string{"docker", "jq", "curl", "sleep", "openssl"} {
		bin := filepath.Join(dir, missing)
		if err := os.WriteFile(bin, []byte("#!/bin/sh\nexit 0\n"), 0o700); err != nil {
			t.Fatal(err)
		}
	}
	t.Setenv("LC_ALL", "C")
	for _, missing := range []string{"docker", "jq", "curl", "sleep", "openssl"} {
		if err := os.Remove(filepath.Join(dir, missing)); err != nil {
			t.Fatal(err)
		}
		t.Setenv("PATH", dir)
		if statusReady() {
			t.Errorf("status ready without %s", missing)
		}
		if err := os.WriteFile(filepath.Join(dir, missing), []byte("#!/bin/sh\nexit 0\n"), 0o700); err != nil {
			t.Fatal(err)
		}
	}
	if !statusReady() {
		t.Fatal("status not ready with all prerequisites")
	}
	t.Setenv("PITHEAD_ENGINE", "podman")
	if statusReady() {
		t.Fatal("status ready without the selected engine")
	}
}

func TestStatusFallsBackForUnsupportedLocale(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "locale"), []byte("#!/bin/sh\nprintf 'ISO-8859-1\\n'\n"), 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", dir)
	t.Setenv("LC_ALL", "fixture")
	if err := Run(filepath.Join(dir, "pithead"), []string{"status"}, &bytes.Buffer{}); !errors.Is(err, ErrFallback) {
		t.Fatalf("error = %v, want fallback", err)
	}
}

func TestVersionFallsBackWhenReferencePathCannotResolve(t *testing.T) {
	reference := filepath.Join(t.TempDir(), "missing", "pithead")
	if err := Run(reference, []string{"version"}, &bytes.Buffer{}); !errors.Is(err, ErrFallback) {
		t.Fatalf("error = %v, want fallback", err)
	}
}

func TestStatusMissingEnvironmentIsNativeExitOne(t *testing.T) {
	dir := t.TempDir()
	for _, name := range []string{"docker", "jq", "curl", "sleep", "openssl"} {
		if err := os.WriteFile(filepath.Join(dir, name), []byte("#!/bin/sh\nexit 0\n"), 0o700); err != nil {
			t.Fatal(err)
		}
	}
	t.Setenv("PATH", dir)
	t.Setenv("LC_ALL", "C")
	err := Run(filepath.Join(dir, "pithead"), []string{"status"}, &bytes.Buffer{})
	var exitError *ExitError
	if !errors.As(err, &exitError) || exitError.Code != 1 {
		t.Fatalf("error = %#v, want exit 1", err)
	}
}

func TestFallbackInvocationPreservesArgumentsAndEnvironment(t *testing.T) {
	dir := t.TempDir()
	bash := filepath.Join(dir, "bash")
	if err := os.WriteFile(bash, []byte("#!/bin/sh\nexit 0\n"), 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", dir)
	t.Setenv("PITHEAD_IMPL", "go")
	t.Setenv("PITHEAD_GO_REFERENCE", "reference")
	args := []string{"unknown", "--flag", "literal value"}
	wantEnv := os.Environ()
	gotBash, gotArgs, gotEnv, err := fallbackInvocation("./pithead", args)
	if err != nil {
		t.Fatal(err)
	}
	if gotBash != bash {
		t.Fatalf("bash = %q, want %q", gotBash, bash)
	}
	if want := []string{"bash", "./pithead", "unknown", "--flag", "literal value"}; !reflect.DeepEqual(gotArgs, want) {
		t.Fatalf("arguments = %q, want %q", gotArgs, want)
	}
	if !reflect.DeepEqual(gotEnv, wantEnv) {
		t.Fatal("fallback environment changed")
	}
	if !reflect.DeepEqual(args, []string{"unknown", "--flag", "literal value"}) {
		t.Fatal("input arguments changed")
	}
}

type brokenPipeWriter struct{}

func (brokenPipeWriter) Write([]byte) (int, error) {
	return 0, syscall.EPIPE
}

type failedWriter struct{}

func (failedWriter) Write([]byte) (int, error) {
	return 0, errors.New("closed")
}
