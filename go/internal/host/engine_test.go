package host

import (
	"os"
	"path/filepath"
	"testing"
)

func TestEngine(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("PATH", dir)

	if got := Engine(); got != "docker" {
		t.Fatalf("missing tools: got %q", got)
	}

	tool(t, dir, "podman")
	if got := Engine(); got != "podman" {
		t.Fatalf("podman only: got %q", got)
	}

	tool(t, dir, "docker")
	if got := Engine(); got != "docker" {
		t.Fatalf("both tools: got %q", got)
	}

	t.Setenv("PITHEAD_ENGINE", "podman")
	if got := Engine(); got != "podman" {
		t.Fatalf("override: got %q", got)
	}

	t.Setenv("PITHEAD_ENGINE", "invalid")
	if got := Engine(); got != "docker" {
		t.Fatalf("invalid override: got %q", got)
	}
}

func tool(t *testing.T, dir, name string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(dir, name), nil, 0o755); err != nil {
		t.Fatal(err)
	}
}
