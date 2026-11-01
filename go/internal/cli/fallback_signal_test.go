package cli

import (
	"os"
	"reflect"
	"syscall"
	"testing"
)

func TestInheritedIgnoredSignals(t *testing.T) {
	env := []string{"PATH=/bin", ignoredSignalsEnvironment + "13,15,bad,0,65"}
	want := []os.Signal{syscall.Signal(13), syscall.Signal(15)}
	got := inheritedIgnoredSignals(env)
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("signals = %v, want %v", got, want)
	}
	if gotEnv := selectedFallbackEnv(env, "current"); !reflect.DeepEqual(gotEnv, []string{"PATH=/bin"}) {
		t.Fatalf("environment = %v", gotEnv)
	}
}
