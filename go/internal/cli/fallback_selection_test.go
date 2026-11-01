package cli

import (
	"reflect"
	"testing"
)

func TestFallbackSelectionPreservesReferenceModesAndRemovesNativeState(t *testing.T) {
	for _, selector := range []string{"", "bash", "python"} {
		env := []string{"PATH=/bin", "PITHEAD_GO_REFERENCE=old", "PITHEAD_GO_CONFIG_DOCUMENT_BINARY=old", "_PITHEAD_GO_HYBRID=1", "_pithead_go_hybrid_binary=stale"}
		want := []string{"PATH=/bin"}
		if selector != "" {
			env = append(env, "PITHEAD_IMPL="+selector)
			want = append(want, "PITHEAD_IMPL="+selector)
		}
		if got := selectedFallbackEnv(env, "current"); !reflect.DeepEqual(got, want) {
			t.Errorf("selector %q: %v; want %v", selector, got, want)
		}
	}
}

func TestFallbackSelectionMarksOnlyHybridLaunch(t *testing.T) {
	env := []string{"PATH=/bin", "PITHEAD_IMPL=go", "PITHEAD_GO_REFERENCE=old", "PITHEAD_GO_CONFIG_DOCUMENT_BINARY=old", "_PITHEAD_GO_HYBRID=stale"}
	want := []string{"PATH=/bin", "PITHEAD_IMPL=bash", "_PITHEAD_GO_HYBRID=1", "PITHEAD_GO_CONFIG_DOCUMENT_BINARY=current"}
	if got := selectedFallbackEnv(env, "current"); !reflect.DeepEqual(got, want) {
		t.Fatal(got)
	}
	if env[3] != "PITHEAD_GO_CONFIG_DOCUMENT_BINARY=old" {
		t.Fatal("input environment changed")
	}
}
