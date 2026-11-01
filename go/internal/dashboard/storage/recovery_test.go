package storage

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestOpenRecoversCorruptFile(t *testing.T) {
	path := filepath.Join(t.TempDir(), "mining.db")
	if err := os.WriteFile(path, []byte(strings.Repeat("not sqlite", 32)), 0o600); err != nil {
		t.Fatal(err)
	}
	for _, suffix := range []string{"-wal", "-shm"} {
		if err := os.WriteFile(path+suffix, []byte("stale"), 0o600); err != nil {
			t.Fatal(err)
		}
	}

	store, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	health := store.Health()
	if !health.Healthy || health.Unrecoverable || health.ResetCount != 1 || health.LastReset == nil {
		t.Fatalf("health = %#v", health)
	}
	if health.LastReset.Quarantine == "" || !strings.HasSuffix(health.LastReset.Quarantine, "Z") {
		t.Fatalf("quarantine = %q", health.LastReset.Quarantine)
	}
	if health.LastReset.Reason != "startup: file is not a database" {
		t.Fatalf("reason = %q", health.LastReset.Reason)
	}
	if _, err := os.Stat(health.LastReset.Quarantine); err != nil {
		t.Fatal(err)
	}
	for _, suffix := range []string{"-wal", "-shm"} {
		contents, err := os.ReadFile(path + suffix)
		if err != nil && !errors.Is(err, os.ErrNotExist) {
			t.Fatal(err)
		}
		if string(contents) == "stale" {
			t.Fatalf("stale sidecar %s remains", suffix)
		}
	}
	if _, err := store.ExecContext(context.Background(), "INSERT INTO history (t, v) VALUES ('now', 1)"); err != nil {
		t.Fatal(err)
	}
}

func TestDBErrorClassifiesRecovery(t *testing.T) {
	store, err := Open(":memory:")
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()

	err = store.DBError("History Update Error", errors.New("database disk image is malformed"))
	if err == nil || !strings.Contains(err.Error(), "History Update Error") {
		t.Fatalf("DBError = %v", err)
	}
	health := store.Health()
	if !health.Healthy || health.Unrecoverable || health.ResetCount != 1 || health.LastReset.Quarantine != "" {
		t.Fatalf("recovered health = %#v", health)
	}

	err = store.DBError("History Update Error", errors.New("database is locked"))
	if err == nil {
		t.Fatal("transient DBError returned nil")
	}
	health = store.Health()
	if health.Healthy || health.Unrecoverable || health.ResetCount != 1 {
		t.Fatalf("transient health = %#v", health)
	}
}

func TestRecoveryFailureAndRetry(t *testing.T) {
	store, err := Open(":memory:")
	if err != nil {
		t.Fatal(err)
	}
	if err := store.RecoverWithSchema("forced failure", func() error { return errors.New("disk full") }); err == nil {
		t.Fatal("Recover returned nil")
	}
	health := store.Health()
	if health.Healthy || !health.Unrecoverable || health.ResetCount != 0 {
		t.Fatalf("failed health = %#v", health)
	}
	if store.DB() == nil {
		t.Fatal("recovery schema failure dropped the replacement handle")
	}
	if err := store.Recover("retry succeeds"); err != nil {
		t.Fatal(err)
	}
	health = store.Health()
	if !health.Healthy || health.Unrecoverable || health.ResetCount != 1 {
		t.Fatalf("retried health = %#v", health)
	}
	store.Close()
}

func TestInitializeWithReportsSchemaFailure(t *testing.T) {
	store, err := OpenConnection(":memory:")
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	if err := store.InitializeWith(context.Background(), func() error { return errors.New("disk full") }); err == nil {
		t.Fatal("InitializeWith returned nil")
	}
	health := store.Health()
	if health.Healthy || health.Unrecoverable || health.ResetCount != 0 {
		t.Fatalf("health = %#v", health)
	}
}

func TestNilSchemaCallbacksFailHealth(t *testing.T) {
	store, err := OpenConnection(":memory:")
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	if err := store.InitializeWith(context.Background(), nil); err == nil || store.Health().Healthy {
		t.Fatalf("InitializeWith nil: error=%v health=%#v", err, store.Health())
	}
	if err := store.RecoverWithSchema("nil", nil); err == nil || !store.Health().Unrecoverable {
		t.Fatalf("RecoverWithSchema nil: error=%v health=%#v", err, store.Health())
	}
}

func TestPruneQuarantinedKeepsNewestThree(t *testing.T) {
	path := filepath.Join(t.TempDir(), "mining.db")
	store, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	for _, stamp := range []string{"20260101T000000Z", "20260102T000000Z", "20260103T000000Z", "20260104T000000Z"} {
		if err := os.WriteFile(path+".corrupt-"+stamp, nil, 0o600); err != nil {
			t.Fatal(err)
		}
	}
	store.PruneQuarantined()
	matches, err := filepath.Glob(path + ".corrupt-*")
	if err != nil {
		t.Fatal(err)
	}
	if len(matches) != 3 {
		t.Fatalf("quarantines = %v", matches)
	}
	if _, err := os.Stat(path + ".corrupt-20260101T000000Z"); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("old quarantine remains: %v", err)
	}
}

func TestOpenReportsNonCorruptionFailure(t *testing.T) {
	store, err := Open(t.TempDir())
	if err == nil {
		if store != nil {
			store.Close()
		}
		t.Fatal("Open directory returned nil error")
	}
	if store == nil || store.Health().Healthy || store.Health().Unrecoverable {
		t.Fatalf("store health = %#v, error = %v", store.Health(), err)
	}
	if IsCorruption(err) {
		t.Fatalf("directory error classified corrupt: %v", err)
	}
}

func TestCorruptionMarkers(t *testing.T) {
	for _, message := range []string{"database disk image is malformed", "file is not a database", "image is malformed", "file is encrypted"} {
		if !IsCorruption(errors.New(message)) {
			t.Fatalf("not classified: %s", message)
		}
	}
	for _, message := range []string{"database is locked", "disk I/O error", "permission denied"} {
		if IsCorruption(errors.New(message)) {
			t.Fatalf("classified transient: %s", message)
		}
	}
}

func TestErrorMessageMatchesPythonSQLite(t *testing.T) {
	store, err := Open(":memory:")
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	if _, err := store.ExecContext(context.Background(), "SELECT * FROM missing"); err == nil || ErrorMessage(err) != "no such table: missing" {
		t.Fatalf("logic error = %q", ErrorMessage(err))
	}
	if _, err := store.ExecContext(context.Background(), "INSERT INTO kv_store VALUES ('key', 'one'), ('key', 'two')"); err == nil || ErrorMessage(err) != "UNIQUE constraint failed: kv_store.key" {
		t.Fatalf("constraint error = %q", ErrorMessage(err))
	}
	if got := ErrorMessage(errors.New("plain error")); got != "plain error" {
		t.Fatalf("plain error = %q", got)
	}
	if got := ErrorMessage(nil); got != "" {
		t.Fatalf("nil error = %q", got)
	}
}
