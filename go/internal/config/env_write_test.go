package config

import (
	"errors"
	"os"
	"path/filepath"
	"syscall"
	"testing"
)

func TestWriteEnvCreatesAndTruncates(t *testing.T) {
	directory := t.TempDir()
	path := filepath.Join(directory, ".env")
	if err := WriteEnv(path, []byte("A=1\nB=2")); err != nil {
		t.Fatal(err)
	}
	content, err := os.ReadFile(path)
	if err != nil || string(content) != "A=1\nB=2\n" {
		t.Fatalf("new content = %q, %v", content, err)
	}
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0o600 {
		t.Fatalf("new mode = %v", info.Mode())
	}
	if err := os.Chmod(path, 0o640); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(directory, "hardlink")
	if err := os.Link(path, link); err != nil {
		t.Fatal(err)
	}
	before, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if err := WriteEnv(path, nil); err != nil {
		t.Fatal(err)
	}
	after, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if !os.SameFile(before, after) || after.Mode().Perm() != 0o640 {
		t.Fatalf("replacement changed inode or mode: %v, %v", os.SameFile(before, after), after.Mode())
	}
	if content, err := os.ReadFile(link); err != nil || string(content) != "\n" {
		t.Fatalf("hardlink content = %q, %v", content, err)
	}
}

func TestWriteEnvRejectsSpecialTargets(t *testing.T) {
	directory := t.TempDir()
	original := filepath.Join(directory, "original")
	if err := os.WriteFile(original, []byte("old"), 0o600); err != nil {
		t.Fatal(err)
	}
	symlink := filepath.Join(directory, "symlink")
	if err := os.Symlink(original, symlink); err != nil {
		t.Fatal(err)
	}
	fifo := filepath.Join(directory, "fifo")
	if err := syscall.Mkfifo(fifo, 0o600); err != nil {
		t.Fatal(err)
	}
	for _, path := range []string{symlink, directory, fifo, filepath.Join(directory, "missing", ".env")} {
		if err := WriteEnv(path, []byte("new")); !errors.Is(err, ErrUnsupportedEnvTarget) {
			t.Fatalf("WriteEnv(%q) = %v", path, err)
		}
	}
	if content, err := os.ReadFile(original); err != nil || string(content) != "old" {
		t.Fatalf("symlink target = %q, %v", content, err)
	}
}
