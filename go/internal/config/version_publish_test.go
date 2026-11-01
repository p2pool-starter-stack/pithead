package config

import (
	"errors"
	"os"
	"path/filepath"
	"syscall"
	"testing"
)

func TestPublishConfigVersionReplacesRegularFile(t *testing.T) {
	directory := t.TempDir()
	path := filepath.Join(directory, "config.json")
	raw := []byte(`{"name":"rig","config_version":"2.0.0"}`)
	if err := os.WriteFile(path, raw, 0o640); err != nil {
		t.Fatal(err)
	}
	before, err := os.Lstat(path)
	if err != nil {
		t.Fatal(err)
	}
	if err := PublishConfigVersion(raw, path, "2.1.0"); err != nil {
		t.Fatal(err)
	}
	after := assertPublishedConfigVersion(t, path, raw, "2.1.0", before)
	if os.SameFile(before, after) {
		t.Fatal("publication retained the old inode")
	}
	assertNoVersionTemps(t, path)
}

func TestPublishConfigVersionReplacesSymlinkAndBreaksHardlink(t *testing.T) {
	for _, linkType := range []string{"symlink", "hardlink"} {
		t.Run(linkType, func(t *testing.T) {
			directory := t.TempDir()
			original := filepath.Join(directory, "original.json")
			path := filepath.Join(directory, "config.json")
			raw := []byte(`{"name":"rig"}`)
			if err := os.WriteFile(original, raw, 0o600); err != nil {
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
			if err := PublishConfigVersion(raw, path, "2.1.0"); err != nil {
				t.Fatal(err)
			}
			after := assertPublishedConfigVersion(t, path, raw, "2.1.0", before)
			if after.Mode()&os.ModeSymlink != 0 || os.SameFile(before, after) {
				t.Fatalf("replacement mode=%v same=%t", after.Mode(), os.SameFile(before, after))
			}
			if content, err := os.ReadFile(original); err != nil || string(content) != string(raw) {
				t.Fatalf("original = %q, %v", content, err)
			}
			assertNoVersionTemps(t, path)
		})
	}
}

func TestPublishConfigVersionRefusesUnsupportedTargets(t *testing.T) {
	directory := t.TempDir()
	raw := []byte(`{"name":"rig"}`)
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
	for _, path := range []string{dirTarget, dirLink, dangling, fifo, filepath.Join(directory, "absent.json")} {
		before, _ := os.Lstat(path)
		err := PublishConfigVersion(raw, path, "2.1.0")
		if err == nil {
			t.Fatalf("PublishConfigVersion(%q) succeeded", path)
		}
		after, afterErr := os.Lstat(path)
		if before == nil {
			if !errors.Is(afterErr, os.ErrNotExist) {
				t.Fatalf("absent target changed: %v", afterErr)
			}
		} else if afterErr != nil || !os.SameFile(before, after) {
			t.Fatalf("target changed: %v", afterErr)
		}
		assertNoVersionTemps(t, path)
	}
}

func TestPublishConfigVersionTransformFailurePreservesFile(t *testing.T) {
	directory := t.TempDir()
	path := filepath.Join(directory, "config.json")
	original := []byte(`{"name":"old"}`)
	if err := os.WriteFile(path, original, 0o640); err != nil {
		t.Fatal(err)
	}
	before, err := os.Lstat(path)
	if err != nil {
		t.Fatal(err)
	}
	for _, test := range []struct {
		raw     []byte
		version string
	}{
		{[]byte(`{"value":1.5}`), "2.1.0"},
		{original, "2.1"},
	} {
		if err := PublishConfigVersion(test.raw, path, test.version); !errors.Is(err, ErrUnsupportedVersion) {
			t.Fatalf("error = %v", err)
		}
		after, err := os.Lstat(path)
		if err != nil || !os.SameFile(before, after) {
			t.Fatalf("target changed: %v", err)
		}
		if content, err := os.ReadFile(path); err != nil || string(content) != string(original) {
			t.Fatalf("content = %q, %v", content, err)
		}
		assertNoVersionTemps(t, path)
	}
}

func TestPublishConfigVersionRenameFailureCleansTemp(t *testing.T) {
	directory := t.TempDir()
	path := filepath.Join(directory, "config.json")
	original := []byte(`{"name":"old"}`)
	if err := os.WriteFile(path, original, 0o640); err != nil {
		t.Fatal(err)
	}
	before, err := os.Lstat(path)
	if err != nil {
		t.Fatal(err)
	}
	renamed := false
	wantErr := errors.New("rename refused")
	err = publishConfigVersion(original, path, "2.1.0", func(temp, target string) error {
		renamed = true
		if target != path {
			t.Fatalf("rename target = %q", target)
		}
		info, statErr := os.Stat(temp)
		if statErr != nil || info.Mode().Perm() != 0o600 {
			t.Fatalf("prepared temp mode = %v, %v", info, statErr)
		}
		return wantErr
	})
	if !renamed || !errors.Is(err, wantErr) {
		t.Fatalf("rename failure = %t, %v", renamed, err)
	}
	after, err := os.Lstat(path)
	if err != nil || !os.SameFile(before, after) {
		t.Fatalf("target changed: %v", err)
	}
	if content, err := os.ReadFile(path); err != nil || string(content) != string(original) {
		t.Fatalf("content = %q, %v", content, err)
	}
	assertNoVersionTemps(t, path)
}

func assertPublishedConfigVersion(t *testing.T, path string, raw []byte, version string, source os.FileInfo) os.FileInfo {
	t.Helper()
	want, err := StampConfigVersion(raw, version)
	if err != nil {
		t.Fatal(err)
	}
	content, err := os.ReadFile(path)
	if err != nil || string(content) != string(want) {
		t.Fatalf("content = %q, %v", content, err)
	}
	info, err := os.Lstat(path)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0o600 || !info.Mode().IsRegular() {
		t.Fatalf("mode = %v", info.Mode())
	}
	sourceOwner, sourceOK := source.Sys().(*syscall.Stat_t)
	actualOwner, actualOK := info.Sys().(*syscall.Stat_t)
	if !sourceOK || !actualOK || sourceOwner.Uid != actualOwner.Uid || sourceOwner.Gid != actualOwner.Gid {
		t.Fatalf("owner = %#v, want %#v", actualOwner, sourceOwner)
	}
	return info
}

func assertNoVersionTemps(t *testing.T, path string) {
	t.Helper()
	matches, err := filepath.Glob(path + ".version.*")
	if err != nil || len(matches) != 0 {
		t.Fatalf("temporary files = %v, %v", matches, err)
	}
}
