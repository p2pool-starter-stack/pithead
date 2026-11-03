package cli

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"
)

func TestReleaseVersion(t *testing.T) {
	for _, tc := range []struct {
		name    string
		version []byte
		want    string
	}{
		{"missing", nil, "pithead unknown (release images dev)\n"},
		{"empty", []byte{}, "pithead unknown (release images dev)\n"},
		{"whitespace", []byte(" \t2.1.0\r\n"), "pithead v2.1.0 (release images v2.1.0)\n"},
		{"literal", []byte("\\n%s"), "pithead v\\n%s (release images v\\n%s)\n"},
		{"bytes", []byte{'2', 0xff}, "pithead v2\xff (release images v2\xff)\n"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			dir := t.TempDir()
			if tc.version != nil {
				writeFile(t, filepath.Join(dir, "VERSION"), tc.version, 0600)
			}
			var output bytes.Buffer
			if err := writeVersion(&output, dir); err != nil {
				t.Fatal(err)
			}
			if output.String() != tc.want {
				t.Fatalf("output = %q, want %q", output.String(), tc.want)
			}
		})
	}
}

func TestSourceVersion(t *testing.T) {
	dir := t.TempDir()
	if err := os.Mkdir(filepath.Join(dir, "dashboard"), 0700); err != nil {
		t.Fatal(err)
	}
	writeFile(t, filepath.Join(dir, "dashboard", "Dockerfile"), nil, 0600)
	writeFile(t, filepath.Join(dir, "VERSION"), []byte("2.1.0\n"), 0600)
	writeFile(t, filepath.Join(dir, "git"), []byte(`#!/bin/sh
case "$*" in
    'rev-parse --git-dir') printf '.git\n' ;;
    'rev-parse --short HEAD') printf 'abcdef0\n' ;;
    'rev-parse --abbrev-ref HEAD') printf 'topic\n' ;;
    'diff --quiet HEAD') exit "${VERSION_TEST_DIFF_EXIT:-0}" ;;
    *) exit 1 ;;
esac
`), 0700)
	t.Setenv("PATH", dir)
	for _, tc := range []struct {
		status string
		want   string
	}{
		{"0", "pithead dev (topic @ abcdef0, VERSION 2.1.0)\n"},
		{"1", "pithead dev (topic @ abcdef0-dirty, VERSION 2.1.0)\n"},
		{"2", "pithead dev (topic @ abcdef0-dirty, VERSION 2.1.0)\n"},
	} {
		t.Setenv("VERSION_TEST_DIFF_EXIT", tc.status)
		var output bytes.Buffer
		if err := writeVersion(&output, dir); err != nil {
			t.Fatal(err)
		}
		if output.String() != tc.want {
			t.Fatalf("diff exit %s: output = %q, want %q", tc.status, output.String(), tc.want)
		}
	}
	if err := os.Remove(filepath.Join(dir, "git")); err != nil {
		t.Fatal(err)
	}
	var output bytes.Buffer
	if err := writeVersion(&output, dir); err != nil {
		t.Fatal(err)
	}
	if want := "pithead dev (unknown @ unknown, VERSION 2.1.0)\n"; output.String() != want {
		t.Fatalf("no git: output = %q, want %q", output.String(), want)
	}
}

func writeFile(t *testing.T, path string, data []byte, mode os.FileMode) {
	t.Helper()
	if err := os.WriteFile(path, data, mode); err != nil {
		t.Fatal(err)
	}
}
