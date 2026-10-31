package status

import (
	"fmt"
	"os"
	"path/filepath"
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
