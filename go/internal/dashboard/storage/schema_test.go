package storage

import (
	"context"
	"database/sql"
	"path/filepath"
	"reflect"
	"sort"
	"testing"
)

func TestOpenCreatesPythonSchema(t *testing.T) {
	store, err := Open(filepath.Join(t.TempDir(), "mining.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()

	wantTables := []string{
		"audit_events", "blocks", "disk_growth", "events", "history", "kv_store",
		"network_history", "payouts", "raffle_wins", "share_stats", "shares",
		"worker_config", "worker_config_revision", "worker_history", "xvb_history",
	}
	if got := objectNames(t, store.DB(), "table"); !reflect.DeepEqual(got, wantTables) {
		t.Fatalf("tables = %v, want %v", got, wantTables)
	}
	wantIndexes := []string{
		"idx_audit_events_ts", "idx_blocks_ts", "idx_disk_growth_ts", "idx_network_history_ts",
		"idx_share_stats_ts", "idx_share_ts", "idx_ts", "idx_worker_config",
		"idx_worker_history_ts", "idx_xvb_history_ts",
	}
	if got := objectNames(t, store.DB(), "index"); !reflect.DeepEqual(got, wantIndexes) {
		t.Fatalf("indexes = %v, want %v", got, wantIndexes)
	}

	wantHistory := []string{
		"t", "v", "v_p2pool", "v_xvb", "timestamp", "v_p2pool_1m", "v_xvb_1m",
		"v_p2pool_1h", "v_xvb_1h", "v_p2pool_12h", "v_xvb_12h", "v_p2pool_24h", "v_xvb_24h",
	}
	if got := columnNames(t, store.DB(), "history"); !reflect.DeepEqual(got, wantHistory) {
		t.Fatalf("history columns = %v, want %v", got, wantHistory)
	}

	var journal string
	if err := store.DB().QueryRow("PRAGMA journal_mode").Scan(&journal); err != nil {
		t.Fatal(err)
	}
	if journal != "wal" {
		t.Fatalf("journal_mode = %q", journal)
	}
	var synchronous, timeout int
	if err := store.DB().QueryRow("PRAGMA synchronous").Scan(&synchronous); err != nil {
		t.Fatal(err)
	}
	if err := store.DB().QueryRow("PRAGMA busy_timeout").Scan(&timeout); err != nil {
		t.Fatal(err)
	}
	if synchronous != 1 || timeout != 30000 {
		t.Fatalf("pragmas synchronous=%d busy_timeout=%d", synchronous, timeout)
	}
}

func TestOpenMigratesLegacySchemaInPlace(t *testing.T) {
	path := filepath.Join(t.TempDir(), "legacy.db")
	db := openRaw(t, path)
	mustExec(t, db, "CREATE TABLE history (t TEXT, v REAL)")
	mustExec(t, db, "INSERT INTO history VALUES ('2026-01-02 03:04:05', 123)")
	mustExec(t, db, "CREATE TABLE workers (name TEXT PRIMARY KEY, ip TEXT, last_seen REAL)")
	mustExec(t, db, "INSERT INTO workers VALUES ('rig1', '192.0.2.1', 10)")
	mustExec(t, db, "CREATE TABLE worker_config (id INTEGER PRIMARY KEY AUTOINCREMENT, worker TEXT, change_id TEXT, ts REAL, status TEXT, changes TEXT, reason TEXT)")
	mustExec(t, db, "INSERT INTO worker_config (worker, change_id, ts, status, changes) VALUES ('rig1', 'cid', 1, 'applied', '{}')")
	mustExec(t, db, "CREATE TABLE worker_config_revision (worker TEXT PRIMARY KEY, revision TEXT, last_change_id TEXT, ts REAL)")
	mustExec(t, db, "INSERT INTO worker_config_revision VALUES ('rig1', 'rev', NULL, 2)")
	if err := db.Close(); err != nil {
		t.Fatal(err)
	}

	store, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()

	history := columnNames(t, store.DB(), "history")
	for _, name := range append([]string{"v_p2pool", "v_xvb", "timestamp"}, historyExtraColumns...) {
		if !contains(history, name) {
			t.Fatalf("history missing %s", name)
		}
	}
	var timestamp, p2pool, xvb float64
	if err := store.DB().QueryRow("SELECT timestamp, v_p2pool, v_xvb FROM history").Scan(&timestamp, &p2pool, &xvb); err != nil {
		t.Fatal(err)
	}
	if timestamp != 1767323045 || p2pool != 0 || xvb != 0 {
		t.Fatalf("migrated history = %v %v %v", timestamp, p2pool, xvb)
	}
	if contains(objectNames(t, store.DB(), "table"), "workers") {
		t.Fatal("workers table was not dropped")
	}
	if !contains(columnNames(t, store.DB(), "worker_config"), "type") {
		t.Fatal("worker_config.type missing")
	}
	var changeType string
	if err := store.DB().QueryRow("SELECT type FROM worker_config WHERE worker='rig1'").Scan(&changeType); err != nil {
		t.Fatal(err)
	}
	if changeType != "apply" {
		t.Fatalf("worker_config.type = %q", changeType)
	}
	if !contains(columnNames(t, store.DB(), "worker_config_revision"), "drift_from") {
		t.Fatal("worker_config_revision.drift_from missing")
	}
	var revision string
	var drift any
	if err := store.DB().QueryRow("SELECT revision, drift_from FROM worker_config_revision WHERE worker='rig1'").Scan(&revision, &drift); err != nil {
		t.Fatal(err)
	}
	if revision != "rev" || drift != nil {
		t.Fatalf("revision row = %q %#v", revision, drift)
	}
}

func TestStoreAccessAndClose(t *testing.T) {
	store, err := Open(":memory:")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := store.ExecContext(context.Background(), "INSERT INTO kv_store VALUES (?, ?)", "key", "value"); err != nil {
		t.Fatal(err)
	}
	rows, err := store.QueryContext(context.Background(), "SELECT value FROM kv_store")
	if err != nil {
		t.Fatal(err)
	}
	rows.Close()
	tx, err := store.BeginTx(context.Background(), nil)
	if err != nil {
		t.Fatal(err)
	}
	if err := tx.Rollback(); err != nil {
		t.Fatal(err)
	}
	if err := store.Close(); err != nil {
		t.Fatal(err)
	}
	if _, err := store.ExecContext(context.Background(), "SELECT 1"); err != ErrClosed {
		t.Fatalf("closed error = %v", err)
	}
}

func TestOpenConnectionDefersSchema(t *testing.T) {
	store, err := OpenConnection(":memory:")
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	if got := objectNames(t, store.DB(), "table"); len(got) != 0 {
		t.Fatalf("tables before Initialize = %v", got)
	}
	if err := store.Initialize(context.Background()); err != nil {
		t.Fatal(err)
	}
	if !contains(objectNames(t, store.DB(), "table"), "history") {
		t.Fatal("history missing after Initialize")
	}
}

func TestApplySchemaMatchesPythonPartialCommit(t *testing.T) {
	for _, test := range []struct {
		name             string
		history          string
		malformed        string
		wantExtraColumns bool
		wantWorkers      bool
		wantWorkerType   bool
	}{
		{"worker-config-ddl-autocommit", "CREATE TABLE history (t TEXT, v REAL, v_p2pool REAL, v_xvb REAL, timestamp REAL)", "worker_config", true, false, false},
		{"worker-config-timestamp-transaction", "CREATE TABLE history (t TEXT, v REAL)", "worker_config", false, true, false},
		{"revision-ddl-autocommit", "CREATE TABLE history (t TEXT, v REAL, v_p2pool REAL, v_xvb REAL, timestamp REAL)", "worker_config_revision", true, false, true},
		{"revision-timestamp-transaction", "CREATE TABLE history (t TEXT, v REAL)", "worker_config_revision", false, true, false},
	} {
		t.Run(test.name, func(t *testing.T) {
			path := filepath.Join(t.TempDir(), "legacy.db")
			db := openRaw(t, path)
			mustExec(t, db, test.history)
			mustExec(t, db, "CREATE TABLE workers (name TEXT)")
			if test.malformed == "worker_config" {
				mustExec(t, db, "CREATE VIEW worker_config AS SELECT 1 AS id")
			} else {
				mustExec(t, db, "CREATE TABLE worker_config (id INTEGER PRIMARY KEY, worker TEXT)")
				mustExec(t, db, "CREATE VIEW worker_config_revision AS SELECT 'rig' AS worker")
			}
			if err := db.Close(); err != nil {
				t.Fatal(err)
			}
			store, err := OpenConnection(path)
			if err != nil {
				t.Fatal(err)
			}
			defer store.Close()
			err = store.ApplySchema(context.Background())
			if err == nil {
				t.Fatal("ApplySchema returned nil")
			}
			if got := ErrorMessage(err); got != "Cannot add a column to a view" {
				t.Fatalf("error = %q", got)
			}
			tables := objectNames(t, store.DB(), "table")
			for _, name := range []string{"history", "kv_store", "shares", "events"} {
				if !contains(tables, name) {
					t.Fatalf("committed table %s missing: %v", name, tables)
				}
			}
			columns := columnNames(t, store.DB(), "history")
			if !contains(columns, "timestamp") {
				t.Fatal("timestamp ALTER did not remain committed")
			}
			if contains(columns, "v_p2pool_1m") != test.wantExtraColumns {
				t.Fatalf("extra columns = %v", columns)
			}
			if contains(tables, "workers") != test.wantWorkers {
				t.Fatalf("workers presence = %v, tables = %v", contains(tables, "workers"), tables)
			}
			if test.malformed == "worker_config_revision" {
				hasType := contains(columnNames(t, store.DB(), "worker_config"), "type")
				if hasType != test.wantWorkerType {
					t.Fatalf("worker_config.type presence = %v", hasType)
				}
			}
			if contains(objectNames(t, store.DB(), "index"), "idx_ts") {
				t.Fatal("indexes created after failed migration")
			}
		})
	}
}

func objectNames(t *testing.T, db *sql.DB, kind string) []string {
	t.Helper()
	rows, err := db.Query("SELECT name FROM sqlite_master WHERE type=? AND name NOT LIKE 'sqlite_%'", kind)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	var names []string
	for rows.Next() {
		var name string
		if err := rows.Scan(&name); err != nil {
			t.Fatal(err)
		}
		names = append(names, name)
	}
	if err := rows.Err(); err != nil {
		t.Fatal(err)
	}
	sort.Strings(names)
	return names
}

func columnNames(t *testing.T, db *sql.DB, table string) []string {
	t.Helper()
	rows, err := db.Query("PRAGMA table_info(" + table + ")")
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	var names []string
	for rows.Next() {
		var cid, notNull, primaryKey int
		var name, columnType string
		var defaultValue any
		if err := rows.Scan(&cid, &name, &columnType, &notNull, &defaultValue, &primaryKey); err != nil {
			t.Fatal(err)
		}
		names = append(names, name)
	}
	return names
}

func openRaw(t *testing.T, path string) *sql.DB {
	t.Helper()
	db, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatal(err)
	}
	return db
}

func mustExec(t *testing.T, db *sql.DB, query string) {
	t.Helper()
	if _, err := db.Exec(query); err != nil {
		t.Fatal(err)
	}
}

func contains(values []string, value string) bool {
	for _, candidate := range values {
		if candidate == value {
			return true
		}
	}
	return false
}
