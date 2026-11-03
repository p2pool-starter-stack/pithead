package status

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"syscall"
	"testing"
)

func TestAttestationMatches(t *testing.T) {
	const inode uint64 = 12345
	const ctime int64 = 1793462400123456789
	valid := fmt.Sprintf(`{"status":"verified","marker":"fixture","inode":%d,"ctime_ns":%d}`, inode, ctime)
	for _, tc := range []struct {
		name, data string
		want       bool
	}{
		{"valid", valid, true},
		{"trailing document", valid + " {}", false},
		{"missing field", `{"status":"verified","marker":"fixture","inode":12345}`, false},
		{"wrong marker", fmt.Sprintf(`{"status":"verified","marker":"other","inode":%d,"ctime_ns":%d}`, inode, ctime), false},
		{"numeric forms", fmt.Sprintf(`{"status":"verified","marker":"fixture","inode":1.2345e4,"ctime_ns":%d}`, ctime), true},
		{"rounded decimal timestamp", fmt.Sprintf(`{"status":"verified","marker":"fixture","inode":12345,"ctime_ns":%d.0}`, ctime), false},
		{"extra field", fmt.Sprintf(`{"status":"verified","marker":"fixture","inode":%d,"ctime_ns":%d,"extra":true}`, inode, ctime), false},
		{"rounded timestamp", fmt.Sprintf(`{"status":"verified","marker":"fixture","inode":%d,"ctime_ns":1793462400123456788}`, inode), false},
		{"boolean inode", fmt.Sprintf(`{"status":"verified","marker":"fixture","inode":true,"ctime_ns":%d}`, ctime), false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if got := attestationMatches("fixture", inode, ctime, []byte(tc.data)); got != tc.want {
				t.Fatalf("attestationMatches = %v, want %v", got, tc.want)
			}
		})
	}
}

func TestAttestationRejectsSymlink(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, ".env"), []byte("CLEARNET_STATE_DIR=.\n"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "marker"), []byte("fixture"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink("marker", filepath.Join(dir, "monero.synced")); err != nil {
		t.Fatal(err)
	}
	r := Runner{Dir: dir, EnvFile: ".env"}
	if r.torAttested("monero") {
		t.Fatal("symlink was accepted")
	}
}

func TestTorAttestedMetadataAndBashParity(t *testing.T) {
	owner := uint32(os.Geteuid())
	for _, tc := range []struct {
		name                   string
		mode                   os.FileMode
		ownerDelta, inodeDelta uint64
		ctimeDelta             int64
		want                   bool
	}{
		{"accepted", 0o600, 0, 0, 0, true},
		{"wrong owner", 0o600, 1, 0, 0, false},
		{"writable mode", 0o620, 0, 0, 0, false},
		{"wrong inode", 0o600, 0, 1, 0, false},
		{"wrong ctime", 0o600, 0, 0, 1, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			dir := t.TempDir()
			stateDir := filepath.Join(dir, "state")
			controlDir := filepath.Join(dir, "control")
			resultsDir := filepath.Join(controlDir, "results")
			if err := os.MkdirAll(stateDir, 0o700); err != nil {
				t.Fatal(err)
			}
			if err := os.MkdirAll(resultsDir, 0o700); err != nil {
				t.Fatal(err)
			}
			marker := filepath.Join(stateDir, "monero.synced")
			if err := os.WriteFile(marker, []byte("fixture\n"), tc.mode); err != nil {
				t.Fatal(err)
			}
			if err := os.Chmod(marker, tc.mode); err != nil {
				t.Fatal(err)
			}
			metadata := pythonFileMetadata(t, marker)
			metadata["inode"] += tc.inodeDelta
			metadata["ctime_ns"] += uint64(tc.ctimeDelta)
			result, err := json.Marshal(map[string]any{
				"status": "verified", "marker": "fixture",
				"inode": metadata["inode"], "ctime_ns": metadata["ctime_ns"],
			})
			if err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(filepath.Join(resultsDir, "clearnet-monero-tor.json"), result, 0o600); err != nil {
				t.Fatal(err)
			}
			env := fmt.Sprintf("CLEARNET_STATE_DIR=%s\nCONTROL_DIR=%s\n", stateDir, controlDir)
			if err := os.WriteFile(filepath.Join(dir, ".env"), []byte(env), 0o600); err != nil {
				t.Fatal(err)
			}
			r := Runner{Dir: dir, EnvFile: ".env"}
			expectedOwner := owner + uint32(tc.ownerDelta)
			if got := r.torAttestedOwnedBy("monero", expectedOwner); got != tc.want {
				t.Fatalf("torAttestedOwnedBy = %v, want %v", got, tc.want)
			}
			if got := bashTorAttested(t, stateDir, controlDir, marker, expectedOwner); got != tc.want {
				t.Fatalf("clearnet_tor_attested = %v, want %v", got, tc.want)
			}
			publicWant := owner == 0 && tc.mode&0o022 == 0 && tc.inodeDelta == 0 && tc.ctimeDelta == 0
			if got := r.torAttested("monero"); got != publicWant {
				t.Fatalf("torAttested = %v, owner = %d", got, owner)
			}
		})
	}
}

func pythonFileMetadata(t *testing.T, path string) map[string]uint64 {
	t.Helper()
	command := exec.Command("python3", "-c", `import json, os, sys
s = os.stat(sys.argv[1])
print(json.dumps({"uid": s.st_uid, "mode": s.st_mode, "inode": s.st_ino, "ctime_ns": s.st_ctime_ns}))`, path)
	output, err := command.Output()
	if err != nil {
		t.Fatal(err)
	}
	var metadata map[string]uint64
	if err := json.Unmarshal(output, &metadata); err != nil {
		t.Fatal(err)
	}
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		t.Fatal("file stat is not syscall.Stat_t")
	}
	if metadata["inode"] != stat.Ino || metadata["ctime_ns"] != uint64(ctimeNS(stat)) {
		t.Fatalf("Python metadata differs from Stat_t: Python %v, Go inode %d ctime %d", metadata, stat.Ino, ctimeNS(stat))
	}
	return metadata
}

func bashTorAttested(t *testing.T, stateDir, controlDir, marker string, owner uint32) bool {
	t.Helper()
	dir := t.TempDir()
	wrapper := filepath.Join(dir, "python3")
	fixture := `#!/usr/bin/env python3
import json, os, sys
from types import SimpleNamespace
metadata = json.loads(os.environ["ATTESTATION_METADATA"])
real_fstat = os.fstat
def normalized_fstat(fd):
    st = real_fstat(fd)
    if fd == 0:
        return st
    return SimpleNamespace(st_uid=metadata["st_uid"], st_mode=st.st_mode,
                           st_ino=st.st_ino, st_ctime_ns=st.st_ctime_ns)
os.fstat = normalized_fstat
sys.argv = sys.argv[1:]
exec(compile(sys.stdin.read(), "<attestation>", "exec"))
`
	if err := os.WriteFile(wrapper, []byte(fixture), 0o700); err != nil {
		t.Fatal(err)
	}
	metadata := pythonFileMetadata(t, marker)
	metadata["st_uid"] = 1
	if metadata["uid"] == uint64(owner) {
		metadata["st_uid"] = 0
	}
	encoded, err := json.Marshal(metadata)
	if err != nil {
		t.Fatal(err)
	}
	repo, err := filepath.Abs(filepath.Join("..", "..", ".."))
	if err != nil {
		t.Fatal(err)
	}
	script := `source "$1"
state_dir="$2"; control_dir="$3"; interpreter="$4"
env_get() { [ "$1" != CONTROL_DIR ] || printf '%s' "$control_dir"; }
clearnet_state_dir() { printf '%s' "$state_dir"; }
python3() { command "$interpreter" "$@"; }
clearnet_tor_attested monero`
	command := exec.Command("bash", "-c", script, "probe", filepath.Join(repo, "lib/pithead/04-status.sh"), stateDir, controlDir, wrapper)
	command.Env = append(os.Environ(), "ATTESTATION_METADATA="+string(encoded))
	err = command.Run()
	if err == nil {
		return true
	}
	if exit, ok := err.(*exec.ExitError); ok && exit.ExitCode() == 1 {
		return false
	}
	t.Fatal(err)
	return false
}
