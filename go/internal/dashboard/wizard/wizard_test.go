package wizard

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

func TestStagePrecedenceAndInstallerBranches(t *testing.T) {
	spool := t.TempDir()
	handoff := t.TempDir()
	view := View{Spool: spool, Handoff: handoff}
	assertStage(t, view, "setup")
	write(t, spool, "disks.tsv", "disk")
	assertStage(t, view, "installer")
	write(t, spool, "applied", "1")
	assertStage(t, view, "installing")
	write(t, spool, "stick", "1")
	assertStage(t, view, "done")
	write(t, handoff, "handoff.json", "{}")
	assertStage(t, view, "handoff")
	write(t, spool, "handoff-ack", "1")
	assertStage(t, view, "done")
	write(t, spool, "installing", "")
	assertStage(t, view, "installing")
	write(t, spool, "setup-failed", "")
	assertStage(t, view, "failed")
}

func TestStageInstallerErrorAndDanglingFiles(t *testing.T) {
	spool := t.TempDir()
	view := View{Spool: spool, Handoff: spool}
	write(t, spool, "error.txt", "bad")
	assertStage(t, view, "setup")
	write(t, spool, "disks.tsv", "")
	assertStage(t, view, "failed")
	if err := os.Remove(filepath.Join(spool, "disks.tsv")); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(filepath.Join(spool, "absent"), filepath.Join(spool, "disks.tsv")); err != nil {
		t.Fatal(err)
	}
	assertStage(t, view, "setup")
}

func TestStageAndStatusPreserveShortCircuitReads(t *testing.T) {
	spool := t.TempDir()
	view := View{Spool: spool}
	write(t, spool, "setup-failed", "")
	if err := os.WriteFile(filepath.Join(spool, "disks.tsv"), []byte{0xff}, 0o600); err != nil {
		t.Fatal(err)
	}
	assertStage(t, view, "failed")
	if err := os.Remove(filepath.Join(spool, "setup-failed")); err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(filepath.Join(spool, "disks.tsv")); err != nil {
		t.Fatal(err)
	}
	write(t, spool, "applied", "1")
	if err := os.WriteFile(filepath.Join(spool, "stick"), []byte{0xff}, 0o600); err != nil {
		t.Fatal(err)
	}
	assertStage(t, view, "done")
	assertStatus(t, view, "Provisioned — the dashboard is coming up now.")
}

func TestStatusMessages(t *testing.T) {
	spool := t.TempDir()
	view := View{Spool: spool}
	assertStatus(t, view, "Waiting for this machine to validate and apply…")
	write(t, spool, "error.txt", "bad wallet")
	assertStatus(t, view, "Rejected: bad wallet — go back and correct the form.")
	write(t, spool, "applied", "1")
	assertStatus(t, view, "Provisioned — the dashboard is coming up now.")
	write(t, spool, "role", "rig")
	assertStatus(t, view, "Rig settings saved. The miner is starting on this machine now — it appears in your Pithead's Workers view once it connects.")
	if err := os.Remove(filepath.Join(spool, "error.txt")); err != nil {
		t.Fatal(err)
	}
	write(t, spool, "disks.tsv", "disk")
	assertStatus(t, view, "Copying the system to the disk…")
	write(t, spool, "installed", "1")
	assertStatus(t, view, "Installed — the machine is switching itself off. Wait for it to go dark, then remove the USB stick and power it back on.")
	if err := os.Remove(filepath.Join(spool, "installed")); err != nil {
		t.Fatal(err)
	}
	write(t, spool, "error.txt", "bad wallet")
	assertStatus(t, view, "Install failed: bad wallet")
}

func TestUnicodeStripAndInvalidUTF8(t *testing.T) {
	spool := t.TempDir()
	view := View{Spool: spool}
	write(t, spool, "value", "\u001c\u2003 value \u00a0\u001f")
	value, err := view.Read("value", "")
	if err != nil || value == nil || *value != "value" {
		t.Fatalf("value=%v err=%v", value, err)
	}
	if err := os.WriteFile(filepath.Join(spool, "bad"), []byte{0xff}, 0o600); err != nil {
		t.Fatal(err)
	}
	response := Handle(Request{Operation: "read", Spool: spool, Name: "bad"})
	if response.Error == nil || response.Error.Kind != "UnicodeDecodeError" || response.Error.Errno != nil {
		t.Fatalf("response=%+v", response)
	}
}

func TestReadUsesExplicitDirectoryAndUniversalNewlines(t *testing.T) {
	spool := t.TempDir()
	handoff := t.TempDir()
	write(t, handoff, "value", "  first\r\nsecond\rthird  ")
	response := Handle(Request{Operation: "read", Spool: spool, Name: "value", Directory: handoff})
	if !response.OK || string(response.Value) != `"first\nsecond\nthird"` {
		t.Fatalf("response=%+v raw=%q", response, response.Value)
	}
}

func TestObjectViewsFailOpenAndPreserveNumbers(t *testing.T) {
	spool := t.TempDir()
	view := View{Spool: spool}
	write(t, spool, "last-attempt.json", `[1,2]`)
	got, err := view.Object("last-attempt.json")
	assertRaw(t, got, err, `{}`)
	write(t, spool, "last-attempt.json", `{`)
	got, err = view.Object("last-attempt.json")
	assertRaw(t, got, err, `{}`)
	write(t, spool, "last-attempt.json", `{"huge":123456789012345678901234567890,"nan":NaN,"inf":Infinity,"nested":{"n":-Infinity}}`)
	got, err = view.Object("last-attempt.json")
	assertRaw(t, got, err, `{"huge":123456789012345678901234567890,"nan":NaN,"inf":Infinity,"nested":{"n":-Infinity}}`)
	if err := os.WriteFile(filepath.Join(spool, "last-attempt.json"), []byte{0xff}, 0o600); err != nil {
		t.Fatal(err)
	}
	got, err = view.Object("last-attempt.json")
	assertRaw(t, got, err, `{}`)
}

func TestReferenceFiltersPrivateAndVersionKeys(t *testing.T) {
	spool := t.TempDir()
	view := View{Spool: spool}
	write(t, spool, "config.reference.json", `{"_private":1,"config_version":"2","keep":{"n":NaN},"also":3}`)
	got, err := view.Reference()
	assertRaw(t, got, err, `{"keep":{"n":NaN},"also":3}`)
}

func TestSavedRoleRequiresNonemptyString(t *testing.T) {
	spool := t.TempDir()
	view := View{Spool: spool}
	for _, invalid := range []string{"{", "[]", `{}`, `{"role":""}`, `{"role":3}`} {
		write(t, spool, "saved-role.json", invalid)
		got, err := view.SavedRole()
		assertRaw(t, got, err, `null`)
	}
	write(t, spool, "saved-role.json", `{"role":"rig","pool":"example.com:3333"}`)
	got, err := view.SavedRole()
	assertRaw(t, got, err, `{"role":"rig","pool":"example.com:3333"}`)
}

func TestRunStreamsSuccessAndErrors(t *testing.T) {
	spool := t.TempDir()
	write(t, spool, "last-attempt.json", `{"n":NaN}`)
	input := strings.NewReader(`{"operation":"stage","spool":` + quoted(spool) + `}` + "\n" +
		`{"operation":"last-attempt","spool":` + quoted(spool) + `}` + "\n" +
		`{"operation":"unknown","spool":` + quoted(spool) + `}` + "\n")
	var output bytes.Buffer
	if err := Run(input, &output); err != nil {
		t.Fatal(err)
	}
	want := "{\"ok\":true,\"value\":\"setup\"}\n" +
		"{\"ok\":true,\"value\":{\"n\":NaN}}\n"
	if !strings.HasPrefix(output.String(), want) || !strings.Contains(output.String(), `"kind":"ValueError"`) {
		t.Fatalf("output=%q", output.String())
	}
}

func TestReadDirectoryReportsErrno(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("directory reads differ on Windows")
	}
	spool := t.TempDir()
	if err := os.Mkdir(filepath.Join(spool, "value"), 0o700); err != nil {
		t.Fatal(err)
	}
	response := Handle(Request{Operation: "read", Spool: spool, Name: "value"})
	if response.Error == nil || response.Error.Kind != "OSError" || response.Error.Errno == nil {
		t.Fatalf("response=%+v", response)
	}
}

func assertStage(t *testing.T, view View, want string) {
	t.Helper()
	got, err := view.Stage()
	if err != nil || got != want {
		t.Fatalf("stage=%q want=%q err=%v", got, want, err)
	}
}

func assertStatus(t *testing.T, view View, want string) {
	t.Helper()
	got, err := view.Status()
	if err != nil || got != want {
		t.Fatalf("status=%q want=%q err=%v", got, want, err)
	}
}

func assertRaw(t *testing.T, got json.RawMessage, err error, want string) {
	t.Helper()
	if err != nil || string(got) != want {
		t.Fatalf("raw=%q want=%q err=%v", got, want, err)
	}
}

func write(t *testing.T, directory, name, value string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(directory, name), []byte(value), 0o600); err != nil {
		t.Fatal(err)
	}
}

func quoted(value string) string {
	encoded, _ := json.Marshal(value)
	return string(encoded)
}
