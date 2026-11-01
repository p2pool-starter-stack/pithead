package config

import (
	"os"
	"path/filepath"
	"testing"
)

func TestPublishTariSecret(t *testing.T) {
	directory := t.TempDir()
	path := filepath.Join(directory, "tari-wallet-secret.env")
	gid := uint32(os.Getegid()) + 1
	if err := PublishTariSecret(path, uint32(os.Geteuid()), gid, "view\nnext", "spend", "password"); err != nil {
		t.Fatal(err)
	}
	content, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	want := "MINOTARI_WALLET_VIEW_PRIVATE_KEY=view\nnext\nMINOTARI_WALLET_SPEND_KEY=spend\nMINOTARI_WALLET_PASSWORD=password\n"
	if string(content) != want {
		t.Fatalf("content = %q", content)
	}
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0o600 {
		t.Fatalf("mode = %v", info.Mode())
	}
	matches, err := filepath.Glob(filepath.Join(directory, ".tari-wallet-secret.*"))
	if err != nil || len(matches) != 0 {
		t.Fatalf("temporary files = %v, %v", matches, err)
	}
}

func TestPublishTariSecretReplacesSymlink(t *testing.T) {
	directory := t.TempDir()
	original := filepath.Join(directory, "original")
	path := filepath.Join(directory, "secret")
	if err := os.WriteFile(original, []byte("original"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(original, path); err != nil {
		t.Fatal(err)
	}
	if err := PublishTariSecret(path, uint32(os.Geteuid()), uint32(os.Getegid()), "v", "s", "p"); err != nil {
		t.Fatal(err)
	}
	info, err := os.Lstat(path)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode()&os.ModeSymlink != 0 {
		t.Fatalf("published path = %v", info.Mode())
	}
	if content, err := os.ReadFile(original); err != nil || string(content) != "original" {
		t.Fatalf("symlink target = %q, %v", content, err)
	}
}

func TestPublishTariSecretFailuresPreserveDestination(t *testing.T) {
	directory := t.TempDir()
	path := filepath.Join(directory, "secret")
	if err := os.WriteFile(path, []byte("old"), 0o600); err != nil {
		t.Fatal(err)
	}
	otherUID := uint32(os.Geteuid()) + 1
	if err := PublishTariSecret(path, otherUID, uint32(os.Getegid()), "v", "s", "p"); err == nil {
		t.Fatal("foreign uid was accepted")
	}
	if content, err := os.ReadFile(path); err != nil || string(content) != "old" {
		t.Fatalf("destination = %q, %v", content, err)
	}
	destinationDirectory := filepath.Join(directory, "destination")
	if err := os.Mkdir(destinationDirectory, 0o700); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(directory, "directory-link")
	if err := os.Symlink(destinationDirectory, link); err != nil {
		t.Fatal(err)
	}
	if err := PublishTariSecret(link, uint32(os.Geteuid()), uint32(os.Getegid()), "v", "s", "p"); err == nil {
		t.Fatal("directory symlink was accepted")
	}
	info, err := os.Lstat(link)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode()&os.ModeSymlink == 0 {
		t.Fatalf("directory symlink = %v", info.Mode())
	}
	matches, err := filepath.Glob(filepath.Join(directory, ".tari-wallet-secret.*"))
	if err != nil || len(matches) != 0 {
		t.Fatalf("temporary files = %v, %v", matches, err)
	}
}
