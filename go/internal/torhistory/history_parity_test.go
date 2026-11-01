//go:build parity

package torhistory

import (
	"bytes"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"testing"
)

var historyBash, _ = exec.LookPath("bash")
var historyJQ, _ = exec.LookPath("jq")

const historyOutage = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"

func historyRecord(outage string, first, last, rounds, observed int64) []byte {
	return []byte(fmt.Sprintf(`{"outage":%s,"first":%d,"last":%d,"rounds":%d,"observed_at":%d}`, strconv.Quote(outage), first, last, rounds, observed))
}

func historyOracle(t *testing.T, operation string, previous []byte, outage string, at, now int64) ([]byte, int) {
	t.Helper()
	if historyBash == "" || historyJQ == "" {
		t.Fatal("Bash and jq are required")
	}
	dir, bin := t.TempDir(), t.TempDir()
	if err := os.Mkdir(filepath.Join(dir, "results"), 0o700); err != nil {
		t.Fatal(err)
	}
	record := filepath.Join(dir, "results", "tor-heal-outage.json")
	if err := os.WriteFile(record, previous, 0o600); err != nil {
		t.Fatal(err)
	}
	for name, path := range map[string]string{"jq": historyJQ, "cat": "/bin/cat"} {
		if err := os.Symlink(path, filepath.Join(bin, name)); err != nil {
			t.Fatal(err)
		}
	}
	for name, output := range map[string]string{"uname": "Linux", "id": "fixture"} {
		if err := os.WriteFile(filepath.Join(bin, name), []byte("#!/bin/sh\nprintf '%s\\n' "+output+"\n"), 0o700); err != nil {
			t.Fatal(err)
		}
	}
	root, err := filepath.Abs(filepath.Join("..", "..", ".."))
	if err != nil {
		t.Fatal(err)
	}
	cmd := exec.Command(historyBash, filepath.Join(root, "tests", "go-parity", "tor_history_reference.sh"),
		root, operation, dir, outage, strconv.FormatInt(at, 10), strconv.FormatInt(now, 10), "", "", "0", "0")
	cmd.Env = []string{"PATH=" + bin, "LC_ALL=C", "TMPDIR=" + t.TempDir()}
	var diagnostics bytes.Buffer
	cmd.Stdout, cmd.Stderr = &diagnostics, &diagnostics
	code := 0
	if err := cmd.Run(); err != nil {
		var status *exec.ExitError
		if !errors.As(err, &status) {
			t.Fatal(err)
		}
		code = status.ExitCode()
	}
	result, err := os.ReadFile(record)
	if err != nil {
		t.Fatal(err)
	}
	if code == 0 && diagnostics.Len() != 0 {
		t.Fatalf("unexpected Bash output: %q", diagnostics.String())
	}
	return result, code
}

func TestTorHistoryTransitionParity(t *testing.T) {
	const now = int64(200000)
	initial := historyRecord(historyOutage, now-1800, now-900, 1, now-1)
	tests := []struct {
		name     string
		previous []byte
		outage   string
		at       int64
	}{
		{"first", []byte(`{}`), historyOutage, now},
		{"first-tombstone", []byte(`{}`), "", now},
		{"future-boundary", []byte(`{}`), historyOutage, now + 60},
		{"past-boundary", []byte(`{}`), historyOutage, now - 300},
		{"second-round", initial, historyOutage, now},
		{"early-round", historyRecord(historyOutage, now-1800, now-899, 1, now-1), historyOutage, now},
		{"late-round", historyRecord(historyOutage, now-1800, now-901, 1, now-1), historyOutage, now},
		{"renew-window", historyRecord(historyOutage, now-100000, now-1800, 2, now-1), historyOutage, now},
		{"new-outage", initial, "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", now},
		{"duplicate", initial, historyOutage, now - 1},
		{"delayed", initial, historyOutage, now - 2},
		{"tombstone", initial, "", now},
		{"equal-tombstone", initial, "", now - 1},
		{"delayed-tombstone", initial, "", now - 2},
		{"tombstone-blocks-delayed", historyRecord("", 0, 0, 0, now), historyOutage, now - 1},
		{"future-stale", initial, historyOutage, now + 61},
		{"past-stale", initial, historyOutage, now - 301},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			want, code := historyOracle(t, "next", test.previous, test.outage, test.at, now)
			got, err := Next(test.previous, test.outage, test.at, now)
			if code != 0 {
				if code != 1 || !errors.Is(err, ErrStaleObservation) || !bytes.Equal(want, test.previous) {
					t.Fatalf("Bash exit %d, record %q; Go %q, %v", code, want, got, err)
				}
				return
			}
			if err != nil || !bytes.Equal(want, append(got, '\n')) {
				t.Fatalf("Bash %q; Go %q, %v", want, got, err)
			}
		})
	}
}

func TestTorHistoryValidityParity(t *testing.T) {
	const now = int64(200000)
	tests := []struct {
		name                string
		first, last, rounds int64
		observed            int64
	}{
		{"valid", now - 1800, now - 900, 2, now},
		{"one-round", now - 1800, now - 900, 1, now},
		{"short-window", now - 899, now, 2, now},
		{"reversed-window", now - 800, now - 900, 2, now},
		{"future-last", now - 1800, now + 1, 2, now},
		{"day-boundary", now - 86400, now - 900, 2, now},
		{"inside-day", now - 86399, now - 900, 2, now},
		{"observed-hour", now - 1800, now - 900, 2, now - 3600},
		{"observed-expired", now - 1800, now - 900, 2, now - 3601},
		{"observed-future-limit", now - 1800, now - 900, 2, now + 60},
		{"observed-future-stale", now - 1800, now - 900, 2, now + 61},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			record := historyRecord(historyOutage, test.first, test.last, test.rounds, test.observed)
			_, code := historyOracle(t, "valid", record, "", 0, now)
			valid, err := Valid(record, now)
			if err != nil || valid != (code == 0) || code > 1 {
				t.Fatalf("Bash exit %d; Go %v, %v", code, valid, err)
			}
		})
	}
}
