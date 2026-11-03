package main

import (
	"bytes"
	"errors"
	"io"
	"os"
	"reflect"
	"testing"

	"github.com/p2pool-starter-stack/pithead/go/internal/cli"
)

func TestInternalInvocation(t *testing.T) {
	t.Setenv("_PITHEAD_GO_NATIVE", "1")
	t.Setenv("_PITHEAD_GO_SCRIPT", "./pithead")
	internal, reference, args, err := invocation([]string{"pithead-go", "status"})
	if err != nil {
		t.Fatal(err)
	}
	if !internal || reference != "./pithead" || !reflect.DeepEqual(args, []string{"status"}) {
		t.Fatalf("internal=%v reference=%q args=%q", internal, reference, args)
	}
}

func TestDirectInvocationUsesReferenceOverride(t *testing.T) {
	t.Setenv("PITHEAD_GO_REFERENCE", "./fixture-pithead")
	internal, reference, args, err := invocation([]string{"pithead-go", "--version"})
	if err != nil {
		t.Fatal(err)
	}
	if internal || reference != "./fixture-pithead" || !reflect.DeepEqual(args, []string{"--version"}) {
		t.Fatalf("internal=%v reference=%q args=%q", internal, reference, args)
	}
	if os.Getenv("PITHEAD_GO_REFERENCE") != "./fixture-pithead" {
		t.Fatal("reference environment changed")
	}
}

func TestInternalInvocationRequiresReference(t *testing.T) {
	t.Setenv("_PITHEAD_GO_NATIVE", "1")
	t.Setenv("_PITHEAD_GO_SCRIPT", "")
	internal, _, _, err := invocation([]string{"pithead-go", "status"})
	if !internal || err == nil {
		t.Fatalf("internal=%v error=%v", internal, err)
	}
}

func TestNativeMarkerArgumentRemainsDirect(t *testing.T) {
	t.Setenv("_PITHEAD_GO_NATIVE", "")
	t.Setenv("PITHEAD_GO_REFERENCE", "./fixture-pithead")
	internal, reference, args, err := invocation([]string{"pithead-go", "--native-cli", "status"})
	if err != nil {
		t.Fatal(err)
	}
	if internal || reference != "./fixture-pithead" || !reflect.DeepEqual(args, []string{"--native-cli", "status"}) {
		t.Fatalf("internal=%v reference=%q args=%q", internal, reference, args)
	}
}

func TestInternalExitEncoding(t *testing.T) {
	tests := []struct {
		err  error
		want int
	}{
		{nil, 200},
		{&cli.ExitError{Code: 1}, 201},
		{&cli.ExitError{Code: 141}, 241},
		{cli.ErrFallback, 125},
		{errors.New("preflight"), 125},
		{&cli.ExitError{Code: 2}, 125},
	}
	for _, test := range tests {
		if got := internalExitCode(test.err); got != test.want {
			t.Errorf("internalExitCode(%v) = %d, want %d", test.err, got, test.want)
		}
	}
}

func TestInternalResultPrintsNativeDiagnostic(t *testing.T) {
	var stderr, receipt bytes.Buffer
	err := &cli.ExitError{Code: 141, Message: "pipe diagnostic"}
	if code := internalResult(err, &stderr, &receipt); code != 241 {
		t.Fatalf("code = %d, want 241", code)
	}
	if stderr.String() != "pipe diagnostic\n" {
		t.Fatalf("stderr = %q", stderr.String())
	}
	if receipt.String() != "pithead-native-v1\n" {
		t.Fatalf("receipt = %q", receipt.String())
	}
	receipt.Reset()
	if code := internalResult(cli.ErrFallback, &stderr, &receipt); code != 125 || receipt.Len() != 0 {
		t.Fatalf("fallback published completion: code=%d receipt=%q", code, receipt.String())
	}
	reader, writer := io.Pipe()
	reader.Close()
	defer writer.Close()
	if code := internalResult(nil, &stderr, writer); code != 125 {
		t.Fatalf("unwritable completion code = %d, want fallback", code)
	}
}
