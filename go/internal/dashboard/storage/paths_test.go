package storage

import (
	"os"
	"path/filepath"
	"testing"
)

func TestDatabaseFilenameIsLiteral(t *testing.T) {
	for _, filename := range []string{"dashboard?mode=memory.db", "dashboard#1%.db", "file:dashboard?mode=memory"} {
		t.Run(filename, func(t *testing.T) {
			path := filepath.Join(t.TempDir(), filename)
			store, err := Open(path)
			if err != nil {
				t.Fatal(err)
			}
			if err := store.Close(); err != nil {
				t.Fatal(err)
			}
			if _, err := os.Stat(path); err != nil {
				t.Fatal(err)
			}
		})
	}
}
