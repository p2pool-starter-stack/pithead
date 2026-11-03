package status

import (
	"errors"
	"os"
	"path/filepath"
	"testing"
)

type failedWriter struct{}

func (failedWriter) Write([]byte) (int, error) {
	return 0, errors.New("closed")
}

func TestWriteErrorChangesSuccessfulStatus(t *testing.T) {
	r := outputFailureRunner(t, &failOnceWriter{}, &discardWriter{}, "")
	if code := r.Run(); code != 1 {
		t.Fatalf("code = %d, want 1", code)
	}
}

func TestStderrWriteErrorKeepsSuccessfulStatus(t *testing.T) {
	r := outputFailureRunner(t, &discardWriter{}, failedWriter{}, "MONERO_CLEARNET_SYNC=true\n")
	if code := r.Run(); code != 0 {
		t.Fatalf("code = %d, want 0", code)
	}
}

func outputFailureRunner(t *testing.T, stdout, stderr interface{ Write([]byte) (int, error) }, env string) *Runner {
	t.Helper()
	dir := t.TempDir()
	docker := `#!/bin/sh
case "$*" in
"compose ps") printf 'fixture compose table\n' ;;
"compose config --services") printf 'caddy\n' ;;
"compose ps -aq") ;;
"compose ps -aq caddy") printf 'fixture-id\n' ;;
"inspect --format {{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}} fixture-id") printf 'running none\n' ;;
*) exit 91 ;;
esac
`
	if err := os.WriteFile(filepath.Join(dir, "docker"), []byte(docker), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, ".env"), []byte(env), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", dir)
	t.Setenv("NO_COLOR", "1")
	return &Runner{Dir: dir, Program: "./pithead", EnvFile: ".env", Out: stdout, Err: stderr}
}

type discardWriter struct{}

func (*discardWriter) Write(value []byte) (int, error) {
	return len(value), nil
}

type failOnceWriter struct {
	failed bool
}

func (w *failOnceWriter) Write(value []byte) (int, error) {
	if !w.failed {
		w.failed = true
		return 0, errors.New("closed")
	}
	return len(value), nil
}
