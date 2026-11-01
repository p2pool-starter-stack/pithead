package cli

import (
	"errors"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
)

func TestConfigTariSecretOwnedMatchingUID(t *testing.T) {
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
	input := strings.Join([]string{path, strconv.Itoa(os.Geteuid()), "4294967295", "v", "s", "p", "0", ""}, "\x00")
	if err := configTariSecretOwned(nil, strings.NewReader(input)); err != nil {
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

func TestConfigTariSecretOwnedForeignUID(t *testing.T) {
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
	input := strings.Join([]string{path, strconv.FormatUint(uint64(targetUID), 10), strconv.FormatUint(uint64(targetGID), 10), "v", "s", "p", "0", ""}, "\x00")
	err := configTariSecretOwned(nil, strings.NewReader(input))
	if probeErr == nil {
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
	} else {
		var status *ExitError
		if !errors.As(err, &status) || status.Code != 125 {
			t.Fatalf("status = %v", err)
		}
		if content, readErr := os.ReadFile(path); readErr != nil || string(content) != "old" {
			t.Fatalf("destination = %q, %v", content, readErr)
		}
	}
	matches, globErr := filepath.Glob(filepath.Join(directory, ".tari-wallet-secret.*"))
	if globErr != nil || len(matches) != 0 {
		t.Fatalf("temporary files = %v, %v", matches, globErr)
	}
}
