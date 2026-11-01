package wizard

import (
	"bytes"
	"errors"
	"io"
	"os"
	"path/filepath"
	"reflect"
	"runtime"
	"strings"
	"syscall"
	"testing"
	"time"
)

type recordingTransactionIO struct {
	events       []string
	replaceError error
	unlinkError  func(string) error
}

func (r *recordingTransactionIO) Replace(source, destination string) error {
	r.events = append(r.events, "replace:"+filepath.Base(source)+":"+filepath.Base(destination))
	if r.replaceError != nil {
		return r.replaceError
	}
	return os.Rename(source, destination)
}

func (r *recordingTransactionIO) Unlink(path string) error {
	r.events = append(r.events, "unlink:"+filepath.Base(path))
	if r.unlinkError != nil {
		if err := r.unlinkError(path); err != nil {
			return err
		}
	}
	return syscall.Unlink(path)
}

func TestTransactionWritePublishesAtomicallyWithPrivateMode(t *testing.T) {
	spool := filepath.Join(t.TempDir(), "spool")
	txn := Txn{Spool: spool, IO: systemTransactionIO{}}
	oldMask := syscall.Umask(0o077)
	t.Cleanup(func() { syscall.Umask(oldMask) })
	if err := txn.Write("config.json", []byte("value"), ""); err != nil {
		t.Fatal(err)
	}
	contents, err := os.ReadFile(filepath.Join(spool, "config.json"))
	if err != nil || string(contents) != "value" {
		t.Fatalf("contents=%q err=%v", contents, err)
	}
	fileInfo, err := os.Stat(filepath.Join(spool, "config.json"))
	if err != nil || fileInfo.Mode().Perm() != 0o600 {
		t.Fatalf("file mode=%v err=%v", fileInfo.Mode().Perm(), err)
	}
	directoryInfo, err := os.Stat(spool)
	if err != nil || directoryInfo.Mode().Perm() != 0o700 {
		t.Fatalf("directory mode=%v err=%v", directoryInfo.Mode().Perm(), err)
	}
	entries, err := os.ReadDir(spool)
	if err != nil || len(entries) != 1 || entries[0].Name() != "config.json" {
		t.Fatalf("entries=%v err=%v", entries, err)
	}
}

func TestTransactionWriteCleanupErrorMasksPublishError(t *testing.T) {
	spool := t.TempDir()
	publishErr := errors.New("publish failed")
	cleanupErr := errors.New("cleanup failed")
	io := &recordingTransactionIO{
		replaceError: publishErr,
		unlinkError:  func(string) error { return cleanupErr },
	}
	err := (Txn{Spool: spool, IO: io}).Write("restore-archive", []byte("secret"), "")
	if !errors.Is(err, cleanupErr) || errors.Is(err, publishErr) {
		t.Fatalf("error=%v", err)
	}
	if len(io.events) != 2 || !strings.HasPrefix(io.events[0], "replace:.restore-archive.") || !strings.HasPrefix(io.events[1], "unlink:.restore-archive.") {
		t.Fatalf("events=%v", io.events)
	}
}

func TestTransactionRemoveIgnoresMissingButRetainsDirectories(t *testing.T) {
	spool := t.TempDir()
	txn := Txn{Spool: spool, IO: systemTransactionIO{}}
	if err := txn.Remove("missing", ""); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(filepath.Join(spool, "unsafe"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := txn.Remove("unsafe", ""); err == nil {
		t.Fatal("directory unlink succeeded")
	}
	if _, err := os.Stat(filepath.Join(spool, "unsafe")); err != nil {
		t.Fatal(err)
	}
}

func TestTransactionRemoveDirectoryResponseCarriesErrno(t *testing.T) {
	spool := t.TempDir()
	if err := os.Mkdir(filepath.Join(spool, "unsafe"), 0o700); err != nil {
		t.Fatal(err)
	}
	response := Handle(Request{Operation: "remove", Spool: spool, Name: "unsafe"})
	if response.Error == nil || response.Error.Kind != "OSError" || response.Error.Errno == nil {
		t.Fatalf("response=%+v", response)
	}
}

func TestTransactionExistsUsesLexistsSemantics(t *testing.T) {
	spool := t.TempDir()
	txn := Txn{Spool: spool, IO: systemTransactionIO{}}
	if err := os.Symlink(filepath.Join(spool, "missing"), filepath.Join(spool, "marker")); err != nil {
		t.Fatal(err)
	}
	if !txn.Exists("marker", "") || txn.Exists("missing", "") {
		t.Fatalf("marker=%v missing=%v", txn.Exists("marker", ""), txn.Exists("missing", ""))
	}
}

func TestTransactionAbsoluteNamesReplaceTheDirectory(t *testing.T) {
	spool := t.TempDir()
	outside := filepath.Join(t.TempDir(), "outside")
	write(t, filepath.Dir(outside), filepath.Base(outside), "value")
	txn := Txn{Spool: spool, IO: systemTransactionIO{}}
	if !txn.Exists(outside, "") {
		t.Fatal("absolute file was not found")
	}
	if err := txn.Remove(outside, ""); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Lstat(outside); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("outside err=%v", err)
	}
}

func TestTransactionPathsPreserveSymlinkDotDotTraversal(t *testing.T) {
	root := t.TempDir()
	spool := filepath.Join(root, "spool")
	realParent := filepath.Join(root, "real")
	realChild := filepath.Join(realParent, "child")
	for _, directory := range []string{spool, realChild} {
		if err := os.MkdirAll(directory, 0o700); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.Symlink(realChild, filepath.Join(spool, "link")); err != nil {
		t.Fatal(err)
	}
	write(t, realParent, "victim", "real")
	write(t, spool, "victim", "spool")
	txn := Txn{Spool: spool, IO: systemTransactionIO{}}
	name := "link/../victim"
	if !txn.Exists(name, "") {
		t.Fatal("symlink traversal target was not found")
	}
	if err := txn.Remove(name, ""); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Lstat(filepath.Join(realParent, "victim")); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("real victim err=%v", err)
	}
	if contents, err := os.ReadFile(filepath.Join(spool, "victim")); err != nil || string(contents) != "spool" {
		t.Fatalf("spool victim=%q err=%v", contents, err)
	}
}

func TestTransactionWriteRejectsAbsoluteNameAsTemporaryPrefix(t *testing.T) {
	spool := t.TempDir()
	outside := filepath.Join(t.TempDir(), "outside")
	err := (Txn{Spool: spool, IO: systemTransactionIO{}}).Write(outside, []byte("value"), "")
	if err == nil {
		t.Fatal("absolute temporary prefix was accepted")
	}
	if _, err := os.Lstat(outside); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("outside err=%v", err)
	}
}

func TestTransactionClearTempsRemovesOnlyFilesAndLinks(t *testing.T) {
	spool := t.TempDir()
	restore := t.TempDir()
	write(t, spool, ".config.json.crash", "secret")
	write(t, restore, ".config.json.", "empty suffix")
	if err := os.Symlink("missing", filepath.Join(restore, ".restore-passphrase.crash")); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(filepath.Join(spool, ".last-attempt.json.crash"), 0o700); err != nil {
		t.Fatal(err)
	}
	write(t, spool, ".unowned.crash", "keep")
	txn := Txn{Spool: spool, Restore: restore, IO: systemTransactionIO{}}
	if txn.ClearTemps() {
		t.Fatal("unsafe directory was accepted")
	}
	for _, path := range []string{
		filepath.Join(spool, ".config.json.crash"),
		filepath.Join(restore, ".config.json."),
		filepath.Join(restore, ".restore-passphrase.crash"),
	} {
		if _, err := os.Lstat(path); !errors.Is(err, os.ErrNotExist) {
			t.Fatalf("path=%s err=%v", path, err)
		}
	}
	for _, path := range []string{
		filepath.Join(spool, ".last-attempt.json.crash"),
		filepath.Join(spool, ".unowned.crash"),
	} {
		if _, err := os.Lstat(path); err != nil {
			t.Fatalf("path=%s err=%v", path, err)
		}
	}
}

func TestTransactionClearTempsRejectsFIFODirectoryWithoutBlocking(t *testing.T) {
	if runtime.GOOS != "darwin" && runtime.GOOS != "linux" {
		t.Skip("FIFO directory behavior is POSIX-specific")
	}
	root := t.TempDir()
	spool := filepath.Join(root, "spool")
	if err := syscall.Mkfifo(spool, 0o600); err != nil {
		t.Fatal(err)
	}
	done := make(chan bool, 1)
	go func() {
		done <- (Txn{Spool: spool, Restore: filepath.Join(root, "missing"), IO: systemTransactionIO{}}).ClearTemps()
	}()
	select {
	case result := <-done:
		if result {
			t.Fatal("FIFO directory was accepted")
		}
	case <-time.After(time.Second):
		t.Fatal("FIFO directory blocked cleanup")
	}
}

func TestTransactionConflictUsesRestorePathWithoutSpoolFallback(t *testing.T) {
	working := t.TempDir()
	previous, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Chdir(working); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chdir(previous) })
	write(t, working, "restore-archive", "archive")
	txn := Txn{Spool: t.TempDir(), IO: systemTransactionIO{}}
	if got := txn.Conflict(); !reflect.DeepEqual(got, conflict(409, "another setup submission is already being processed")) {
		t.Fatalf("conflict=%v", got)
	}
}

func TestTransactionClearRestorePreservesRemovalOrderAndContinues(t *testing.T) {
	spool := t.TempDir()
	restore := t.TempDir()
	io := &recordingTransactionIO{unlinkError: func(path string) error {
		if filepath.Base(path) == "config.json" {
			return errors.New("fixture failure")
		}
		return nil
	}}
	txn := Txn{Spool: spool, Restore: restore, IO: io}
	if txn.ClearRestore() {
		t.Fatal("cleanup failure was hidden")
	}
	want := []string{"restore-passphrase", "restore-archive"}
	want = append(want, rollbackFiles...)
	got := make([]string, len(io.events))
	for index, event := range io.events {
		got[index] = strings.TrimPrefix(event, "unlink:")
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("got=%v want=%v", got, want)
	}
}

func TestTransactionConflictPrecedenceAndOrphanCleanup(t *testing.T) {
	spool := t.TempDir()
	restore := t.TempDir()
	txn := Txn{Spool: spool, Restore: restore, IO: systemTransactionIO{}}
	write(t, restore, "restore-passphrase", "secret")
	write(t, spool, "submission-active", "1")
	if got := txn.Conflict(); got != nil {
		t.Fatalf("conflict=%v", got)
	}
	if txn.Exists("restore-passphrase", restore) {
		t.Fatal("orphan passphrase remains")
	}
	write(t, restore, "restore-archive", "archive")
	write(t, restore, "restore-passphrase", "secret")
	if got := txn.Conflict(); !reflect.DeepEqual(got, conflict(409, "another setup submission is already being processed")) {
		t.Fatalf("conflict=%v", got)
	}
	if !txn.Exists("restore-passphrase", restore) {
		t.Fatal("archive conflict cleared passphrase")
	}
}

func TestRunTransactionCallbacksOwnTheSelectedIO(t *testing.T) {
	spool := t.TempDir()
	input := strings.NewReader(
		`{"operation":"write","spool":` + quoted(spool) + `,"name":"config.json","data":"dmFsdWU=","io_hooks":{"replace":true}}` + "\n" +
			`{"ok":true}` + "\n")
	var output bytes.Buffer
	if err := Run(input, &output); err != nil {
		t.Fatal(err)
	}
	lines := strings.Split(strings.TrimSpace(output.String()), "\n")
	if len(lines) != 2 || !strings.Contains(lines[0], `"event":"replace"`) || lines[1] != `{"ok":true,"value":null}` {
		t.Fatalf("output=%q", output.String())
	}
	if _, err := os.Stat(filepath.Join(spool, "config.json")); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("destination err=%v", err)
	}
	entries, err := os.ReadDir(spool)
	if err != nil || len(entries) != 1 || !strings.HasPrefix(entries[0].Name(), ".config.json.") {
		t.Fatalf("entries=%v err=%v", entries, err)
	}
}

func TestRunTransactionCallbackErrorPreservesMessageAndErrno(t *testing.T) {
	spool := t.TempDir()
	input := strings.NewReader(
		`{"operation":"remove","spool":` + quoted(spool) + `,"name":"config.json","io_hooks":{"unlink":true}}` + "\n" +
			`{"ok":false,"error":{"message":"fixture denied","errno":13}}` + "\n")
	var output bytes.Buffer
	if err := Run(input, &output); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(output.String(), `{"event":"unlink"`) || !strings.Contains(output.String(), `"message":"fixture denied","errno":13`) {
		t.Fatalf("output=%q", output.String())
	}
}

func TestRunWriteStreamsBinaryBody(t *testing.T) {
	spool := t.TempDir()
	body := []byte{'a', '\n', 0, 'b', 0xff}
	header := `{"operation":"write","spool":` + quoted(spool) + `,"name":"restore-archive","length":5}` + "\n"
	var output bytes.Buffer
	if err := RunWrite(io.MultiReader(strings.NewReader(header), bytes.NewReader(body)), &output); err != nil {
		t.Fatal(err)
	}
	if output.String() != `{"ok":true,"value":null}`+"\n" {
		t.Fatalf("output=%q", output.String())
	}
	contents, err := os.ReadFile(filepath.Join(spool, "restore-archive"))
	if err != nil || !bytes.Equal(contents, body) {
		t.Fatalf("contents=%v err=%v", contents, err)
	}
}

func TestRunWriteShortBodyCleansTemporary(t *testing.T) {
	spool := t.TempDir()
	header := `{"operation":"write","spool":` + quoted(spool) + `,"name":"restore-archive","length":8}` + "\n"
	var output bytes.Buffer
	if err := RunWrite(strings.NewReader(header+"short"), &output); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(output.String(), `"ok":false`) {
		t.Fatalf("output=%q", output.String())
	}
	entries, err := os.ReadDir(spool)
	if err != nil || len(entries) != 0 {
		t.Fatalf("entries=%v err=%v", entries, err)
	}
}

func TestRunWriteCallbackStartsAfterTheRawBody(t *testing.T) {
	spool := t.TempDir()
	header := `{"operation":"write","spool":` + quoted(spool) + `,"name":"config.json","length":5,"io_hooks":{"replace":true}}` + "\n"
	input := io.MultiReader(strings.NewReader(header), strings.NewReader("value"), strings.NewReader(`{"ok":true}`+"\n"))
	var output bytes.Buffer
	if err := RunWrite(input, &output); err != nil {
		t.Fatal(err)
	}
	lines := strings.Split(strings.TrimSpace(output.String()), "\n")
	if len(lines) != 2 || !strings.Contains(lines[0], `"event":"replace"`) || lines[1] != `{"ok":true,"value":null}` {
		t.Fatalf("output=%q", output.String())
	}
	if _, err := os.Stat(filepath.Join(spool, "config.json")); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("destination err=%v", err)
	}
}
