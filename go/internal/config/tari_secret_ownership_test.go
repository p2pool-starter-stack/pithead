package config

import (
	"os"
	"path/filepath"
	"syscall"
	"testing"
)

func TestPublishTariSecretWithOwnershipIgnoresGIDForMatchingUID(t *testing.T) {
	directory := t.TempDir()
	control := filepath.Join(directory, "control")
	if err := os.WriteFile(control, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	controlInfo, err := os.Stat(control)
	if err != nil {
		t.Fatal(err)
	}
	controlStat, ok := controlInfo.Sys().(*syscall.Stat_t)
	if !ok {
		t.Fatal("control owner unavailable")
	}
	path := filepath.Join(directory, "secret")
	if err := PublishTariSecretWithOwnership(path, uint32(os.Geteuid()), ^uint32(0), "v", "s", "p"); err != nil {
		t.Fatal(err)
	}
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok || stat.Uid != uint32(os.Geteuid()) || stat.Gid != controlStat.Gid {
		t.Fatalf("owner = %#v", stat)
	}
}

func TestPublishTariSecretWithOwnershipRepair(t *testing.T) {
	directory := t.TempDir()
	path := filepath.Join(directory, "secret")
	if err := os.WriteFile(path, []byte("old"), 0o600); err != nil {
		t.Fatal(err)
	}
	targetUID := uint32(os.Geteuid()) + 1
	targetGID := uint32(os.Getegid())
	control := filepath.Join(directory, "control")
	if err := os.WriteFile(control, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	probeErr := os.Chown(control, int(targetUID), int(targetGID))
	err := PublishTariSecretWithOwnership(path, targetUID, targetGID, "v", "s", "p")
	if probeErr != nil {
		if err == nil {
			t.Fatal("ownership repair succeeded without chown capability")
		}
		if content, readErr := os.ReadFile(path); readErr != nil || string(content) != "old" {
			t.Fatalf("destination = %q, %v", content, readErr)
		}
	} else {
		if err != nil {
			t.Fatal(err)
		}
		info, statErr := os.Stat(path)
		if statErr != nil {
			t.Fatal(statErr)
		}
		stat, ok := info.Sys().(*syscall.Stat_t)
		if !ok || stat.Uid != targetUID || stat.Gid != targetGID {
			t.Fatalf("owner = %#v", stat)
		}
	}
	matches, globErr := filepath.Glob(filepath.Join(directory, ".tari-wallet-secret.*"))
	if globErr != nil || len(matches) != 0 {
		t.Fatalf("temporary files = %v, %v", matches, globErr)
	}
}

func TestPublishTariSecretWithOwnershipRejectsSentinels(t *testing.T) {
	directory := t.TempDir()
	path := filepath.Join(directory, "secret")
	for _, owner := range [][2]uint32{{^uint32(0), uint32(os.Getegid())}, {uint32(os.Geteuid()) + 1, ^uint32(0)}} {
		if err := os.WriteFile(path, []byte("old"), 0o600); err != nil {
			t.Fatal(err)
		}
		if err := PublishTariSecretWithOwnership(path, owner[0], owner[1], "v", "s", "p"); err == nil {
			t.Fatalf("owner %v was accepted", owner)
		}
		if content, err := os.ReadFile(path); err != nil || string(content) != "old" {
			t.Fatalf("destination = %q, %v", content, err)
		}
	}
}
