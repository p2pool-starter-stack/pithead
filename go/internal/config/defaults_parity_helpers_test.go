//go:build parity

package config

import (
	"bytes"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

type defaultsCase struct {
	operation, platform, mode, path string
	document, table                 []byte
	unsupported                     bool
}

type defaultsObservation struct {
	output, diagnostic []byte
	code               int
}

func defaultsRoot() string {
	_, file, _, _ := runtime.Caller(0)
	return filepath.Clean(filepath.Join(filepath.Dir(file), "..", "..", ".."))
}

func defaultsTable(t *testing.T) []byte {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join(defaultsRoot(), "lib/pithead/19a-config-defaults.sh"))
	if err != nil {
		t.Fatal(err)
	}
	_, tail, found := strings.Cut(string(raw), "    cat <<'PITHEAD_DEFAULTS_JSON'\n")
	table, _, closed := strings.Cut(tail, "\nPITHEAD_DEFAULTS_JSON")
	if !found || !closed {
		t.Fatal("embedded defaults table boundary changed")
	}
	return []byte(table)
}

func observeDefaults(t *testing.T, test defaultsCase, selected bool, dir string) defaultsObservation {
	t.Helper()
	configPath, tablePath := filepath.Join(dir, "config.json"), filepath.Join(dir, "table.json")
	for path, raw := range map[string][]byte{configPath: test.document, tablePath: test.table} {
		if raw != nil {
			if err := os.WriteFile(path, raw, 0o600); err != nil {
				t.Fatal(err)
			}
		}
	}
	command := exec.Command("bash", filepath.Join(defaultsRoot(), "tests/go-parity/config_defaults_reference.sh"),
		defaultsRoot(), test.operation, test.platform, configPath, tablePath, test.mode, test.path)
	implementation := "bash"
	if selected {
		implementation = "go"
	}
	command.Env = append(os.Environ(), "DEFAULTS_PARITY_IMPL="+implementation, "PITHEAD_GO_BINARY="+filepath.Join(defaultsRoot(), "go/bin/pithead"))
	var output, diagnostic bytes.Buffer
	command.Stdout, command.Stderr = &output, &diagnostic
	code := 0
	if err := command.Run(); err != nil {
		var status *exec.ExitError
		if !errors.As(err, &status) {
			t.Fatal("defaults oracle failed to launch")
		}
		code = status.ExitCode()
	}
	return defaultsObservation{output.Bytes(), diagnostic.Bytes(), code}
}

func compareDefaults(t *testing.T, test defaultsCase) {
	t.Helper()
	if test.table == nil {
		test.table = defaultsTable(t)
	}
	dir := t.TempDir()
	want := observeDefaults(t, test, false, dir)
	defaults, err := NewDefaults(test.table)
	var output []byte
	if err == nil {
		switch test.operation {
		case "defaults":
			output, err = defaults.Render(test.mode, test.platform)
		case "default":
			output, err = defaults.DefaultOf(test.path, test.mode, test.platform)
		case "install":
			output, err = defaults.NewInstall(test.platform)
		case "get":
			output, err = defaults.Get(test.path, test.document, test.platform)
		}
	}
	if test.unsupported {
		if output != nil || !errors.Is(err, ErrUnsupportedDefaults) {
			t.Fatal("compatibility input did not defer without bytes")
		}
		got := observeDefaults(t, test, true, dir)
		if got.code != want.code || !bytes.Equal(got.output, want.output) || !bytes.Equal(got.diagnostic, want.diagnostic) {
			t.Fatal("selected fallback bytes or status differ from jq")
		}
		return
	}
	if err != nil || want.code != 0 || len(want.diagnostic) != 0 || !bytes.Equal(output, want.output) {
		t.Fatal("native defaults bytes or status differ from jq")
	}
}
