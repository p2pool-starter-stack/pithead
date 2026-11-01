//go:build parity

package firewall

import (
	"bytes"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func TestTorSyncParity(t *testing.T) {
	tests := []struct {
		name  string
		state TorSyncState
		mark  []string
	}{
		{"all", TorSyncState{Prefix: "10.20.3", Monero: "true", Tari: "true", P2Pool: "true", XVBEnabled: "true", XVBTor: "false"}, nil},
		{"defaults", TorSyncState{Monero: "true", Tari: "true"}, nil},
		{"exact-booleans", TorSyncState{Monero: "TRUE", Tari: " true", P2Pool: "1", XVBEnabled: "true", XVBTor: "FALSE"}, nil},
		{"trailing-lines", TorSyncState{Prefix: "10.2.4\n\n", Monero: "true\n", Tari: "true\n", P2Pool: "true\n", XVBEnabled: "true\n", XVBTor: "false\n"}, nil},
		{"embedded-prefix-line", TorSyncState{Prefix: "left\nright", P2Pool: "true"}, nil},
		{"closed-monero", TorSyncState{CloseChain: "monero", Monero: "true", Tari: "true"}, nil},
		{"closed-tari", TorSyncState{CloseChain: "tari", Monero: "true", Tari: "true"}, nil},
		{"raw-close", TorSyncState{CloseChain: "monero\n", Monero: "true", Tari: "true"}, nil},
		{"regular-marker", TorSyncState{Monero: "true", Tari: "true"}, []string{"monero.synced"}},
		{"directory-marker", TorSyncState{Monero: "true", Tari: "true"}, []string{"tari.synced/"}},
		{"dangling-marker", TorSyncState{Monero: "true", Tari: "true"}, []string{"monero.synced@"}},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			dir := t.TempDir()
			for _, marker := range test.mark {
				path := filepath.Join(dir, strings.TrimRight(marker, "/@"))
				switch marker[len(marker)-1] {
				case '/':
					if err := os.Mkdir(path, 0o700); err != nil {
						t.Fatal(err)
					}
				case '@':
					if err := os.Symlink("missing", path); err != nil {
						t.Fatal(err)
					}
				default:
					if err := os.WriteFile(path, nil, 0o600); err != nil {
						t.Fatal(err)
					}
				}
			}
			test.state.StateDir = dir + "\n"
			want := runTorSyncBash(t, test.state)
			got, err := test.state.IPs()
			if err != nil {
				t.Fatal(err)
			}
			output := ""
			if len(got) > 0 {
				output = strings.Join(got, "\n") + "\n"
			}
			if want.code != 0 || want.stderr != "" || want.stdout != output {
				t.Fatalf("Bash = exit %d, %q, %q; Go = %v", want.code, want.stdout, want.stderr, got)
			}
		})
	}
}

type torSyncResult struct {
	stdout string
	stderr string
	code   int
}

func runTorSyncBash(t *testing.T, state TorSyncState) torSyncResult {
	t.Helper()
	bash, err := exec.LookPath("bash")
	if err != nil {
		t.Fatal(err)
	}
	root, err := filepath.Abs(filepath.Join("..", "..", ".."))
	if err != nil {
		t.Fatal(err)
	}
	bin := t.TempDir()
	writeEgressTool(t, bin, "uname", "printf 'Linux\\n'\n")
	writeEgressTool(t, bin, "id", "printf 'fixture\\n'\n")
	args := []string{
		filepath.Join(root, "tests", "go-parity", "tor_sync_reference.sh"), root,
		state.Prefix, state.CloseChain, state.StateDir, state.Monero, state.Tari,
		state.P2Pool, state.XVBEnabled, state.XVBTor,
	}
	command := exec.Command(bash, args...)
	command.Env = []string{"PATH=" + bin, "LC_ALL=C", "TMPDIR=" + t.TempDir()}
	var stdout, stderr bytes.Buffer
	command.Stdout, command.Stderr = &stdout, &stderr
	code := 0
	if err := command.Run(); err != nil {
		var status *exec.ExitError
		if !errors.As(err, &status) {
			t.Fatal(err)
		}
		code = status.ExitCode()
	}
	return torSyncResult{stdout.String(), stderr.String(), code}
}
