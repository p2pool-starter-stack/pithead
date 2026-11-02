package wizard

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"syscall"
	"testing"
)

type terminalTransactionIO struct {
	events      []string
	unlinkError func(string) error
}

func (t *terminalTransactionIO) Replace(source, destination string) error {
	t.events = append(t.events, "replace:"+filepath.Base(destination))
	return os.Rename(source, destination)
}

func (t *terminalTransactionIO) Unlink(path string) error {
	t.events = append(t.events, "unlink:"+filepath.Base(path))
	if t.unlinkError != nil {
		if err := t.unlinkError(path); err != nil {
			return err
		}
	}
	return syscall.Unlink(path)
}

func TestHandleTerminalHandoff(t *testing.T) {
	handoff := t.TempDir()
	request := TerminalRequest{Operation: "handoff", Authenticated: true, Handoff: handoff}

	result, err := HandleTerminal(request)
	if err != nil || result.Status != 404 || !reflect.DeepEqual(result.Body, map[string]string{"error": "not ready"}) {
		t.Fatalf("missing result=%#v err=%v", result, err)
	}
	writeTerminalFile(t, handoff, "handoff.json", " \n\t")
	result, err = HandleTerminal(request)
	if err != nil || result.Status != 404 {
		t.Fatalf("empty result=%#v err=%v", result, err)
	}
	want := `{"token":"\u263a","url":"https://pithead"}`
	writeTerminalFile(t, handoff, "handoff.json", want)
	result, err = HandleTerminal(request)
	if err != nil || result.Status != 200 || result.Raw == nil || *result.Raw != want {
		t.Fatalf("ready result=%#v err=%v", result, err)
	}
	if !reflect.DeepEqual(result.Headers, map[string]string{"Cache-Control": "no-store"}) {
		t.Fatalf("headers=%#v", result.Headers)
	}
}

func TestHandleTerminalHandoffAuthenticationAndReadErrors(t *testing.T) {
	result, err := HandleTerminal(TerminalRequest{Operation: "handoff", Handoff: filepath.Join(t.TempDir(), "absent")})
	if err != nil || result.Status != 401 {
		t.Fatalf("unauthenticated result=%#v err=%v", result, err)
	}
	handoff := t.TempDir()
	if err := os.Mkdir(filepath.Join(handoff, "handoff.json"), 0o700); err != nil {
		t.Fatal(err)
	}
	_, err = HandleTerminal(TerminalRequest{Operation: "handoff", Authenticated: true, Handoff: handoff})
	if err == nil {
		t.Fatal("directory read succeeded")
	}
}

func TestHandleTerminalHandoffFallsBackToSpool(t *testing.T) {
	spool := t.TempDir()
	writeTerminalFile(t, spool, "handoff.json", `{"token":"fallback"}`)
	result, err := HandleTerminal(TerminalRequest{Operation: "handoff", Authenticated: true, Spool: &spool})
	if err != nil || result.Status != 200 || result.Raw == nil || *result.Raw != `{"token":"fallback"}` {
		t.Fatalf("result=%#v err=%v", result, err)
	}
}

func TestHandleTerminalAcknowledgeUsesSeparateHandoff(t *testing.T) {
	spool := t.TempDir()
	handoff := t.TempDir()
	request := TerminalRequest{Operation: "ack", Authenticated: true, Spool: &spool, Handoff: handoff}

	result, err := HandleTerminal(request)
	if err != nil || result.Status != 400 {
		t.Fatalf("missing result=%#v err=%v", result, err)
	}
	writeTerminalFile(t, handoff, "handoff.json", "")
	result, err = HandleTerminal(request)
	if err != nil || result.Status != 200 || !reflect.DeepEqual(result.Body, map[string]string{"status": "provisioning"}) {
		t.Fatalf("ack result=%#v err=%v", result, err)
	}
	marker := filepath.Join(spool, "handoff-ack")
	contents, readErr := os.ReadFile(marker)
	info, statErr := os.Stat(marker)
	if readErr != nil || statErr != nil || string(contents) != "1" || info.Mode().Perm() != 0o600 {
		t.Fatalf("contents=%q mode=%v readErr=%v statErr=%v", contents, info.Mode(), readErr, statErr)
	}
}

func TestHandleTerminalAcknowledgeAndKeepRedirectBeforeIO(t *testing.T) {
	io := &terminalTransactionIO{unlinkError: func(string) error { panic("filesystem reached") }}
	for _, operation := range []string{"ack", "keep", "retry"} {
		result, err := handleTerminal(TerminalRequest{Operation: operation}, io)
		if err != nil || result.Status != 302 || result.Redirect != "/" {
			t.Fatalf("operation=%s result=%#v err=%v", operation, result, err)
		}
	}
}

func TestHandleTerminalKeep(t *testing.T) {
	spool := t.TempDir()
	request := TerminalRequest{Operation: "keep", Authenticated: true, Spool: &spool}
	result, err := HandleTerminal(request)
	if err != nil || result.Status != 400 {
		t.Fatalf("missing result=%#v err=%v", result, err)
	}
	writeTerminalFile(t, spool, "saved-role.json", `{"role":"host"}`)
	result, err = HandleTerminal(request)
	if err != nil || result.Status != 200 || !reflect.DeepEqual(result.Body, map[string]string{"status": "kept"}) {
		t.Fatalf("keep result=%#v err=%v", result, err)
	}
	contents, readErr := os.ReadFile(filepath.Join(spool, "keep-role"))
	if readErr != nil || string(contents) != "1" {
		t.Fatalf("contents=%q err=%v", contents, readErr)
	}
}

func TestHandleTerminalRetryGuardsAndLazySpool(t *testing.T) {
	for _, stage := range []any{"setup", nil, []any{}, false, json.Number("0")} {
		result, err := HandleTerminal(TerminalRequest{Operation: "retry", Authenticated: true, Stage: stage})
		if err != nil || result.Status != 409 || result.NeedSpool {
			t.Fatalf("stage=%#v result=%#v err=%v", stage, result, err)
		}
	}
	result, err := HandleTerminal(TerminalRequest{Operation: "retry", Authenticated: true, Stage: "failed"})
	if err != nil || !result.NeedSpool {
		t.Fatalf("lazy result=%#v err=%v", result, err)
	}
}

func TestHandleTerminalRetryStopsAtFirstUnlinkError(t *testing.T) {
	spool := t.TempDir()
	for _, name := range []string{"error.txt", "installing", "setup-failed"} {
		writeTerminalFile(t, spool, name, "1")
	}
	wantErr := errors.New("unlink failed")
	io := &terminalTransactionIO{unlinkError: func(path string) error {
		if filepath.Base(path) == "installing" {
			return wantErr
		}
		return nil
	}}
	_, err := handleTerminal(TerminalRequest{Operation: "retry", Authenticated: true, Stage: "failed", Spool: &spool}, io)
	if !errors.Is(err, wantErr) {
		t.Fatalf("error=%v", err)
	}
	if !reflect.DeepEqual(io.events, []string{"unlink:error.txt", "unlink:installing"}) {
		t.Fatalf("events=%#v", io.events)
	}
	if _, err := os.Stat(filepath.Join(spool, "error.txt")); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("error marker err=%v", err)
	}
	if _, err := os.Stat(filepath.Join(spool, "setup-failed")); err != nil {
		t.Fatalf("setup marker err=%v", err)
	}
}

func TestHandleTerminalRetrySymlinks(t *testing.T) {
	spool := t.TempDir()
	target := filepath.Join(spool, "target")
	writeTerminalFile(t, spool, "target", "1")
	if err := os.Symlink(target, filepath.Join(spool, "error.txt")); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(filepath.Join(spool, "missing"), filepath.Join(spool, "installing")); err != nil {
		t.Fatal(err)
	}
	result, err := HandleTerminal(TerminalRequest{Operation: "retry", Authenticated: true, Stage: "failed", Spool: &spool})
	if err != nil || result.Status != 200 {
		t.Fatalf("result=%#v err=%v", result, err)
	}
	if _, err := os.Lstat(filepath.Join(spool, "error.txt")); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("valid symlink err=%v", err)
	}
	if _, err := os.Lstat(filepath.Join(spool, "installing")); err != nil {
		t.Fatalf("broken symlink err=%v", err)
	}
	if _, err := os.Stat(target); err != nil {
		t.Fatalf("target err=%v", err)
	}
}

func TestHandleTerminalRejectsUnknownOperation(t *testing.T) {
	_, err := HandleTerminal(TerminalRequest{Operation: "unknown"})
	var validation ValidationError
	if !errors.As(err, &validation) {
		t.Fatalf("error=%v", err)
	}
}

func writeTerminalFile(t *testing.T, directory, name, contents string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(directory, name), []byte(contents), 0o600); err != nil {
		t.Fatal(err)
	}
}
