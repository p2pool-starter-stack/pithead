package storage

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"

	sqlite "modernc.org/sqlite"
)

const corruptKeep = 3

var corruptionMarkers = []string{"malformed", "not a database", "image is malformed", "file is encrypted"}

var ErrClosed = errors.New("dashboard storage is closed")

type Reset struct {
	Time       float64
	Reason     string
	Quarantine string
}

type Health struct {
	Healthy       bool
	Unrecoverable bool
	ResetCount    uint64
	LastReset     *Reset
}

type Store struct {
	path     string
	dbMu     sync.RWMutex
	db       *sql.DB
	recovery sync.Mutex
	health   sync.RWMutex
	state    Health
	openDB   func(string) (*sql.DB, error)
}

func Open(path string) (*Store, error) {
	s, err := OpenConnection(path)
	if err != nil {
		return s, err
	}
	return s, s.Initialize(context.Background())
}

func OpenConnection(path string) (*Store, error) {
	s := &Store{path: path, state: Health{Healthy: true}, openDB: openConnection}
	db, err := s.openDB(path)
	if err != nil {
		s.markFailed(false)
		return s, err
	}
	s.db = db
	return s, nil
}

func openConnection(path string) (*sql.DB, error) {
	dsn := path
	if path != "" && path != ":memory:" {
		absolute, err := filepath.Abs(path)
		if err != nil {
			return nil, err
		}
		dsn = (&url.URL{Scheme: "file", Path: filepath.ToSlash(absolute)}).String()
	}
	db, err := sql.Open("sqlite", dsn)
	if err != nil {
		return nil, err
	}
	db.SetMaxOpenConns(1)
	if _, err := db.Exec("PRAGMA busy_timeout=30000"); err != nil {
		if IsCorruption(err) {
			return db, nil
		}
		_ = db.Close()
		return nil, err
	}
	if err := db.Ping(); err != nil {
		if IsCorruption(err) {
			return db, nil
		}
		_ = db.Close()
		return nil, err
	}
	return db, nil
}

func (s *Store) Initialize(ctx context.Context) error {
	return s.InitializeWith(ctx, func() error { return s.ApplySchema(ctx) })
}

func (s *Store) InitializeWith(ctx context.Context, schema func() error) error {
	if schema == nil {
		s.markFailed(false)
		return errors.New("DB Init Error: schema callback is nil")
	}
	if err := s.CheckIntegrity(ctx); err != nil {
		if IsCorruption(err) {
			return s.RecoverWithSchema("startup: "+ErrorMessage(err), schema)
		}
		s.markFailed(false)
		return err
	}
	if err := schema(); err != nil {
		if IsCorruption(err) {
			return s.RecoverWithSchema("startup: "+ErrorMessage(err), schema)
		}
		s.markFailed(false)
		return err
	}
	return nil
}

func (s *Store) ApplySchema(ctx context.Context) error {
	db, err := s.current()
	if err != nil {
		return err
	}
	return applySchema(ctx, db)
}

func (s *Store) CheckIntegrity(ctx context.Context) error {
	db, err := s.current()
	if err != nil {
		return err
	}
	var result string
	if err := db.QueryRowContext(ctx, "PRAGMA integrity_check").Scan(&result); err != nil {
		return err
	}
	if result != "ok" {
		return fmt.Errorf("integrity_check reported the database is malformed: %s", result)
	}
	return nil
}

func IsCorruption(err error) bool {
	if err == nil {
		return false
	}
	text := strings.ToLower(err.Error())
	for _, marker := range corruptionMarkers {
		if strings.Contains(text, marker) {
			return true
		}
	}
	return false
}

func ErrorMessage(err error) string {
	if err == nil {
		return ""
	}
	message := err.Error()
	var sqliteError *sqlite.Error
	if !errors.As(err, &sqliteError) {
		return message
	}
	message = strings.TrimSuffix(message, fmt.Sprintf(" (%d)", sqliteError.Code()))
	switch sqliteError.Code() & 0xff {
	case 1:
		message = strings.Replace(message, "SQL logic error: ", "", 1)
	case 19:
		message = strings.Replace(message, "constraint failed: ", "", 1)
	}
	return message
}

func (s *Store) Recover(reason string) error {
	return s.RecoverWithSchema(reason, func() error { return s.ApplySchema(context.Background()) })
}

func (s *Store) RecoverWithSchema(reason string, schema func() error) error {
	if schema == nil {
		s.markFailed(true)
		return errors.New("DB Recovery Error: schema callback is nil")
	}
	s.recovery.Lock()
	defer s.recovery.Unlock()
	stamp := time.Now().UTC().Format("20060102T150405Z")
	quarantine := ""
	s.dbMu.Lock()
	if s.db != nil {
		_ = s.db.Close()
		s.db = nil
	}
	if s.path != ":memory:" {
		if _, err := os.Stat(s.path); err == nil {
			quarantine = s.path + ".corrupt-" + stamp
			if err := os.Rename(s.path, quarantine); err != nil {
				s.dbMu.Unlock()
				s.markFailed(true)
				return fmt.Errorf("DB Recovery Error: %w", err)
			}
			for _, suffix := range []string{"-wal", "-shm"} {
				_ = os.Remove(s.path + suffix)
			}
			s.pruneQuarantined()
		} else if !errors.Is(err, os.ErrNotExist) {
			s.dbMu.Unlock()
			s.markFailed(true)
			return fmt.Errorf("DB Recovery Error: %w", err)
		}
	}
	db, err := s.openDB(s.path)
	if err == nil {
		s.db = db
	}
	s.dbMu.Unlock()
	if err == nil {
		err = schema()
	}
	if err != nil {
		s.markFailed(true)
		return fmt.Errorf("DB Recovery Error: %w", err)
	}
	s.health.Lock()
	s.state.Healthy = true
	s.state.Unrecoverable = false
	s.state.ResetCount++
	s.state.LastReset = &Reset{Time: float64(time.Now().UnixNano()) / 1e9, Reason: reason, Quarantine: quarantine}
	s.health.Unlock()
	return nil
}

func (s *Store) DBError(where string, err error) error {
	if err == nil {
		return nil
	}
	s.markFailed(false)
	if where != "DB Recovery Error" && IsCorruption(err) {
		if recoverErr := s.Recover(where + ": " + ErrorMessage(err)); recoverErr != nil {
			return recoverErr
		}
	}
	return fmt.Errorf("%s: %w", where, err)
}

func (s *Store) Health() Health {
	s.health.RLock()
	defer s.health.RUnlock()
	result := s.state
	if s.state.LastReset != nil {
		reset := *s.state.LastReset
		result.LastReset = &reset
	}
	return result
}

func (s *Store) DB() *sql.DB {
	s.dbMu.RLock()
	defer s.dbMu.RUnlock()
	return s.db
}

func (s *Store) ExecContext(ctx context.Context, query string, args ...any) (sql.Result, error) {
	db, err := s.current()
	if err != nil {
		return nil, err
	}
	return db.ExecContext(ctx, query, args...)
}

func (s *Store) QueryContext(ctx context.Context, query string, args ...any) (*sql.Rows, error) {
	db, err := s.current()
	if err != nil {
		return nil, err
	}
	return db.QueryContext(ctx, query, args...)
}

func (s *Store) BeginTx(ctx context.Context, opts *sql.TxOptions) (*sql.Tx, error) {
	db, err := s.current()
	if err != nil {
		return nil, err
	}
	return db.BeginTx(ctx, opts)
}

func (s *Store) Close() error {
	s.dbMu.Lock()
	defer s.dbMu.Unlock()
	if s.db == nil {
		return nil
	}
	err := s.db.Close()
	s.db = nil
	return err
}

func (s *Store) current() (*sql.DB, error) {
	s.dbMu.RLock()
	defer s.dbMu.RUnlock()
	if s.db == nil {
		return nil, ErrClosed
	}
	return s.db, nil
}

func (s *Store) markFailed(unrecoverable bool) {
	s.health.Lock()
	s.state.Healthy = false
	if unrecoverable {
		s.state.Unrecoverable = true
	}
	s.health.Unlock()
}

func (s *Store) PruneQuarantined() {
	s.pruneQuarantined()
}

func (s *Store) pruneQuarantined() {
	directory := filepath.Dir(s.path)
	base := filepath.Base(s.path) + ".corrupt-"
	entries, err := os.ReadDir(directory)
	if err != nil {
		return
	}
	var names []string
	for _, entry := range entries {
		if strings.HasPrefix(entry.Name(), base) {
			names = append(names, entry.Name())
		}
	}
	sort.Strings(names)
	for _, name := range names[:max(0, len(names)-corruptKeep)] {
		_ = os.Remove(filepath.Join(directory, name))
	}
}
