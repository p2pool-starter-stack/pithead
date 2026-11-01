//go:build parity

package config

import (
	"bytes"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"testing"
)

func compareDocument(t *testing.T, raw []byte, request, unsupported bool) {
	t.Helper()
	path := filepath.Join(t.TempDir(), "config.json")
	if raw != nil {
		if err := os.WriteFile(path, raw, 0o600); err != nil {
			t.Fatal(err)
		}
	}
	_, file, _, _ := runtime.Caller(0)
	root := filepath.Clean(filepath.Join(filepath.Dir(file), "..", "..", ".."))
	mode := "config"
	if request {
		mode = "request"
	}
	command := exec.Command("bash", filepath.Join(root, "tests/go-parity/config_document_reference.sh"), root, path, mode)
	var output, diagnostic bytes.Buffer
	command.Stdout, command.Stderr = &output, &diagnostic
	wantCode := 0
	if err := command.Run(); err != nil {
		var status *exec.ExitError
		if !errors.As(err, &status) {
			t.Fatal("Bash document oracle failed to launch")
		}
		wantCode = status.ExitCode()
	}
	if diagnostic.Len() != 0 || wantCode > 1 {
		t.Fatal("Bash document oracle exposed a diagnostic or abnormal exit")
	}
	reason, err := ValidateDocumentFile(path, request)
	if unsupported {
		if reason != "" || !errors.Is(err, ErrUnsupportedDocument) {
			t.Fatal("compatibility input did not defer to the reference")
		}
		binary := filepath.Join(root, "go/bin/pithead")
		if _, err := os.Stat(binary); err != nil {
			t.Fatal("run make go-build before tagged compatibility comparisons")
		}
		selected := exec.Command("bash", "-c", `source "$1"; config_document_error "$2" "$3"`, "test",
			filepath.Join(root, "lib/pithead/22a-config-document.sh"), path, mode)
		selected.Env = append(os.Environ(), "PITHEAD_IMPL=go", "PITHEAD_GO_BINARY="+binary, "PITHEAD_GO_CONFIG_DOCUMENT_BINARY=")
		var got, diagnostic bytes.Buffer
		selected.Stdout, selected.Stderr = &got, &diagnostic
		code := 0
		if err := selected.Run(); err != nil {
			var status *exec.ExitError
			if !errors.As(err, &status) {
				t.Fatal("selected compatibility gate failed to launch")
			}
			code = status.ExitCode()
		}
		if code != wantCode || got.String() != output.String() || diagnostic.Len() != 0 {
			t.Fatal("selected compatibility reason bytes or status differ from Bash")
		}
		return
	}
	if err != nil {
		t.Fatal("native parser unexpectedly deferred")
	}
	got, gotCode := "", 0
	if reason != "" {
		got, gotCode = reason+"\n", 1
	}
	if got != output.String() || gotCode != wantCode {
		t.Fatal("document reason bytes or exit status differ from Bash")
	}
}
