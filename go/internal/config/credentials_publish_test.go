package config

import (
	"errors"
	"os"
	"path/filepath"
	"syscall"
	"testing"
)

func TestPublishNodeCredentialsReplacesWithPrivateCurrentOwnerFile(t *testing.T) {
	directory := t.TempDir()
	path := filepath.Join(directory, "config.json")
	raw := []byte(`{"first":1,"monero":{"mode":"local"}}`)
	if err := os.WriteFile(path, raw, 0o640); err != nil {
		t.Fatal(err)
	}
	targetUID := os.Geteuid() + 1
	if os.Geteuid() == 0 {
		targetUID = 1
	}
	ownerChanged := false
	if targetUID != os.Geteuid() {
		ownerChanged = os.Chown(path, targetUID, -1) == nil
	}
	before, err := os.Lstat(path)
	if err != nil {
		t.Fatal(err)
	}
	beforeOwner, ok := before.Sys().(*syscall.Stat_t)
	if !ok || ownerChanged && beforeOwner.Uid != uint32(targetUID) {
		t.Fatalf("source owner = %#v, changed = %t", beforeOwner, ownerChanged)
	}
	oldUmask := syscall.Umask(0o777)
	defer syscall.Umask(oldUmask)
	if err := PublishNodeCredentials(raw, path, "user", "p\n\x01é"); err != nil {
		t.Fatal(err)
	}
	after, err := os.Lstat(path)
	if err != nil {
		t.Fatal(err)
	}
	if os.SameFile(before, after) || after.Mode().Perm() != 0o600 || !after.Mode().IsRegular() {
		t.Fatalf("replacement same=%t mode=%v", os.SameFile(before, after), after.Mode())
	}
	owner, ok := after.Sys().(*syscall.Stat_t)
	if !ok || owner.Uid != uint32(os.Geteuid()) {
		t.Fatalf("owner = %#v, effective uid = %d", owner, os.Geteuid())
	}
	want := "{\n  \"first\": 1,\n  \"monero\": {\n    \"mode\": \"local\",\n    \"node_username\": \"user\",\n    \"node_password\": \"p\\n\\u0001é\"\n  }\n}\n"
	if content, err := os.ReadFile(path); err != nil || string(content) != want {
		t.Fatalf("content = %q, %v", content, err)
	}
	assertNoCredentialStage(t, path)
}

func TestPublishNodeCredentialsReplacesSymlinkAndBreaksHardlink(t *testing.T) {
	for _, linkType := range []string{"symlink", "hardlink"} {
		t.Run(linkType, func(t *testing.T) {
			directory := t.TempDir()
			original := filepath.Join(directory, "original.json")
			path := filepath.Join(directory, "config.json")
			raw := []byte(`{"monero":{}}`)
			if err := os.WriteFile(original, raw, 0o640); err != nil {
				t.Fatal(err)
			}
			var err error
			if linkType == "symlink" {
				err = os.Symlink(original, path)
			} else {
				err = os.Link(original, path)
			}
			if err != nil {
				t.Fatal(err)
			}
			before, err := os.Lstat(path)
			if err != nil {
				t.Fatal(err)
			}
			if err := PublishNodeCredentials(raw, path, "user", "pass"); err != nil {
				t.Fatal(err)
			}
			after, err := os.Lstat(path)
			if err != nil || after.Mode()&os.ModeSymlink != 0 || os.SameFile(before, after) {
				t.Fatalf("replacement = %v, %v", after, err)
			}
			if content, err := os.ReadFile(original); err != nil || string(content) != string(raw) {
				t.Fatalf("original = %q, %v", content, err)
			}
			assertNoCredentialStage(t, path)
		})
	}
}

func TestPublishNodeCredentialsRefusesExistingStage(t *testing.T) {
	for _, kind := range []string{"file", "directory", "symlink", "fifo"} {
		t.Run(kind, func(t *testing.T) {
			directory := t.TempDir()
			path := filepath.Join(directory, "config.json")
			stage := path + ".tmp"
			raw := []byte(`{"monero":{}}`)
			if err := os.WriteFile(path, raw, 0o640); err != nil {
				t.Fatal(err)
			}
			var err error
			switch kind {
			case "file":
				err = os.WriteFile(stage, []byte("existing"), 0o644)
			case "directory":
				err = os.Mkdir(stage, 0o700)
			case "symlink":
				err = os.Symlink(filepath.Join(directory, "missing"), stage)
			case "fifo":
				err = syscall.Mkfifo(stage, 0o600)
			}
			if err != nil {
				t.Fatal(err)
			}
			before, err := os.Lstat(stage)
			if err != nil {
				t.Fatal(err)
			}
			if err := PublishNodeCredentials(raw, path, "user", "pass"); !errors.Is(err, ErrUnsupportedCredentialTarget) {
				t.Fatalf("error = %v", err)
			}
			after, err := os.Lstat(stage)
			if err != nil || !os.SameFile(before, after) {
				t.Fatalf("stage changed: %v", err)
			}
			if content, err := os.ReadFile(path); err != nil || string(content) != string(raw) {
				t.Fatalf("config = %q, %v", content, err)
			}
		})
	}
}

func TestPublishNodeCredentialsRefusesUnsupportedTargetsAndDocuments(t *testing.T) {
	directory := t.TempDir()
	raw := []byte(`{"monero":{}}`)
	dirTarget := filepath.Join(directory, "target-dir")
	if err := os.Mkdir(dirTarget, 0o700); err != nil {
		t.Fatal(err)
	}
	dirLink := filepath.Join(directory, "dir-link")
	if err := os.Symlink(dirTarget, dirLink); err != nil {
		t.Fatal(err)
	}
	dangling := filepath.Join(directory, "dangling")
	if err := os.Symlink(filepath.Join(directory, "missing"), dangling); err != nil {
		t.Fatal(err)
	}
	fifo := filepath.Join(directory, "fifo")
	if err := syscall.Mkfifo(fifo, 0o600); err != nil {
		t.Fatal(err)
	}
	for _, path := range []string{dirTarget, dirLink, dangling, fifo, filepath.Join(directory, "absent")} {
		if err := PublishNodeCredentials(raw, path, "user", "pass"); err == nil {
			t.Fatalf("PublishNodeCredentials(%q) succeeded", path)
		}
		assertNoCredentialStage(t, path)
	}
	path := filepath.Join(directory, "config.json")
	original := []byte(`{"monero":{}}`)
	if err := os.WriteFile(path, original, 0o640); err != nil {
		t.Fatal(err)
	}
	before, err := os.Lstat(path)
	if err != nil {
		t.Fatal(err)
	}
	if err := PublishNodeCredentials([]byte(`{"value":1.5}`), path, "user", "pass"); !errors.Is(err, ErrUnsupportedPersistence) {
		t.Fatalf("error = %v", err)
	}
	after, err := os.Lstat(path)
	if err != nil || !os.SameFile(before, after) {
		t.Fatalf("config changed: %v", err)
	}
	assertNoCredentialStage(t, path)
}

func TestPublishNodeCredentialsRenameFailureCleansStage(t *testing.T) {
	directory := t.TempDir()
	path := filepath.Join(directory, "config.json")
	raw := []byte(`{"monero":{}}`)
	if err := os.WriteFile(path, raw, 0o640); err != nil {
		t.Fatal(err)
	}
	before, err := os.Lstat(path)
	if err != nil {
		t.Fatal(err)
	}
	wantErr := errors.New("rename refused")
	renamed := false
	want, err := PersistNodeCredentials(raw, "user", "pass")
	if err != nil {
		t.Fatal(err)
	}
	err = publishNodeCredentials(raw, path, "user", "pass", func(stage, target string) error {
		renamed = true
		if target != path {
			t.Fatalf("target = %q", target)
		}
		info, statErr := os.Stat(stage)
		content, readErr := os.ReadFile(stage)
		if statErr != nil || readErr != nil || info.Mode().Perm() != 0o600 || string(content) != string(want) {
			t.Fatalf("stage = %v, %q, %v, %v", info, content, statErr, readErr)
		}
		return wantErr
	})
	if !renamed || !errors.Is(err, wantErr) {
		t.Fatalf("rename failure = %t, %v", renamed, err)
	}
	after, err := os.Lstat(path)
	if err != nil || !os.SameFile(before, after) {
		t.Fatalf("config changed: %v", err)
	}
	assertNoCredentialStage(t, path)
}

func assertNoCredentialStage(t *testing.T, path string) {
	t.Helper()
	if _, err := os.Lstat(path + ".tmp"); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("stage remains: %v", err)
	}
}
