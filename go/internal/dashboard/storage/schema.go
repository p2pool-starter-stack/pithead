package storage

import (
	"context"
	"database/sql"
	"fmt"
)

var historyExtraColumns = []string{
	"v_p2pool_1m", "v_xvb_1m",
	"v_p2pool_1h", "v_xvb_1h",
	"v_p2pool_12h", "v_xvb_12h",
	"v_p2pool_24h", "v_xvb_24h",
}

var tableStatements = []string{
	"CREATE TABLE IF NOT EXISTS history (t TEXT, v REAL, v_p2pool REAL, v_xvb REAL, timestamp REAL, v_p2pool_1m REAL DEFAULT 0, v_xvb_1m REAL DEFAULT 0, v_p2pool_1h REAL DEFAULT 0, v_xvb_1h REAL DEFAULT 0, v_p2pool_12h REAL DEFAULT 0, v_xvb_12h REAL DEFAULT 0, v_p2pool_24h REAL DEFAULT 0, v_xvb_24h REAL DEFAULT 0)",
	"CREATE TABLE IF NOT EXISTS kv_store (key TEXT PRIMARY KEY, value TEXT)",
	"CREATE TABLE IF NOT EXISTS shares (ts REAL PRIMARY KEY, difficulty REAL)",
	"CREATE TABLE IF NOT EXISTS events (ts REAL, type TEXT, detail TEXT)",
	"CREATE TABLE IF NOT EXISTS share_stats (ts REAL, accepted INTEGER, rejected INTEGER, invalid INTEGER, expired INTEGER)",
	"CREATE TABLE IF NOT EXISTS payouts (chain TEXT, txid TEXT, height INTEGER, ts REAL, amount_atomic INTEGER, PRIMARY KEY (chain, txid))",
	"CREATE TABLE IF NOT EXISTS worker_config (id INTEGER PRIMARY KEY AUTOINCREMENT, worker TEXT, change_id TEXT, ts REAL, status TEXT, changes TEXT, reason TEXT, type TEXT DEFAULT 'apply')",
	"CREATE TABLE IF NOT EXISTS blocks (ts REAL, height INTEGER, difficulty REAL)",
	"CREATE TABLE IF NOT EXISTS raffle_wins (block_id TEXT PRIMARY KEY, ts REAL, hashrate REAL, height INTEGER, tier TEXT)",
	"CREATE TABLE IF NOT EXISTS xvb_history (ts REAL, avg_1h REAL, avg_24h REAL, fail_count INTEGER, donation_fraction REAL, mode TEXT)",
	"CREATE TABLE IF NOT EXISTS network_history (ts REAL, difficulty REAL, height INTEGER, reward REAL, pool_hashrate REAL)",
	"CREATE TABLE IF NOT EXISTS disk_growth (ts REAL, monero_db_bytes INTEGER, disk_used_gb REAL, disk_total_gb REAL)",
	"CREATE TABLE IF NOT EXISTS worker_history (ts REAL, name TEXT, h15 REAL, accepted INTEGER, rejected INTEGER)",
	"CREATE TABLE IF NOT EXISTS audit_events (id TEXT PRIMARY KEY, ts TEXT, source TEXT, actor TEXT, action TEXT, status TEXT, keys TEXT)",
	"CREATE TABLE IF NOT EXISTS worker_config_revision (worker TEXT PRIMARY KEY, revision TEXT, last_change_id TEXT, ts REAL, drift_from TEXT)",
}

var indexStatements = []string{
	"CREATE INDEX IF NOT EXISTS idx_ts ON history(timestamp)",
	"CREATE INDEX IF NOT EXISTS idx_share_ts ON shares(ts)",
	"CREATE INDEX IF NOT EXISTS idx_share_stats_ts ON share_stats(ts)",
	"CREATE INDEX IF NOT EXISTS idx_worker_config ON worker_config(worker, ts)",
	"CREATE INDEX IF NOT EXISTS idx_blocks_ts ON blocks(ts)",
	"CREATE INDEX IF NOT EXISTS idx_xvb_history_ts ON xvb_history(ts)",
	"CREATE INDEX IF NOT EXISTS idx_network_history_ts ON network_history(ts)",
	"CREATE INDEX IF NOT EXISTS idx_disk_growth_ts ON disk_growth(ts)",
	"CREATE INDEX IF NOT EXISTS idx_worker_history_ts ON worker_history(ts)",
	"CREATE INDEX IF NOT EXISTS idx_audit_events_ts ON audit_events(ts)",
}

func applySchema(ctx context.Context, db *sql.DB) error {
	conn, err := db.Conn(ctx)
	if err != nil {
		return err
	}
	defer conn.Close()
	if _, err := conn.ExecContext(ctx, "PRAGMA busy_timeout=30000"); err != nil {
		return err
	}
	if _, err := conn.ExecContext(ctx, "PRAGMA journal_mode=WAL"); err != nil {
		return err
	}
	if _, err := conn.ExecContext(ctx, "PRAGMA synchronous=NORMAL"); err != nil {
		return err
	}
	for _, statement := range tableStatements {
		if _, err := conn.ExecContext(ctx, statement); err != nil {
			return err
		}
	}
	tx, err := migrate(ctx, conn)
	if err != nil {
		return err
	}
	var executor sqlExecutor = conn
	if tx != nil {
		executor = tx
	}
	for _, statement := range indexStatements {
		if _, err := executor.ExecContext(ctx, statement); err != nil {
			if tx != nil {
				_ = tx.Rollback()
			}
			return err
		}
	}
	if tx != nil {
		return tx.Commit()
	}
	return nil
}

type sqlExecutor interface {
	ExecContext(context.Context, string, ...any) (sql.Result, error)
	QueryContext(context.Context, string, ...any) (*sql.Rows, error)
}

func migrate(ctx context.Context, conn *sql.Conn) (*sql.Tx, error) {
	var executor sqlExecutor = conn
	var tx *sql.Tx
	fail := func(err error) (*sql.Tx, error) {
		if tx != nil {
			_ = tx.Rollback()
		}
		return nil, err
	}
	history, err := columns(ctx, executor, "history")
	if err != nil {
		return fail(err)
	}
	for _, migration := range []struct {
		name string
		sql  string
	}{
		{"v_p2pool", "ALTER TABLE history ADD COLUMN v_p2pool REAL DEFAULT 0"},
		{"v_xvb", "ALTER TABLE history ADD COLUMN v_xvb REAL DEFAULT 0"},
		{"timestamp", "ALTER TABLE history ADD COLUMN timestamp REAL"},
	} {
		if !history[migration.name] {
			if _, err := executor.ExecContext(ctx, migration.sql); err != nil {
				return fail(err)
			}
			if migration.name == "timestamp" {
				tx, err = conn.BeginTx(ctx, nil)
				if err != nil {
					return nil, err
				}
				executor = tx
				if _, err := executor.ExecContext(ctx, "UPDATE history SET timestamp = CAST(strftime('%s', t) AS REAL) WHERE timestamp IS NULL"); err != nil {
					return fail(err)
				}
				if _, err := executor.ExecContext(ctx, "UPDATE history SET timestamp = 0 WHERE timestamp IS NULL"); err != nil {
					return fail(err)
				}
			}
		}
	}
	for _, name := range historyExtraColumns {
		if !history[name] {
			if _, err := executor.ExecContext(ctx, "ALTER TABLE history ADD COLUMN "+name+" REAL DEFAULT 0"); err != nil {
				return fail(err)
			}
		}
	}
	if _, err := executor.ExecContext(ctx, "DROP TABLE IF EXISTS workers"); err != nil {
		return fail(err)
	}
	workerConfig, err := columns(ctx, executor, "worker_config")
	if err != nil {
		return fail(err)
	}
	if !workerConfig["type"] {
		if _, err := executor.ExecContext(ctx, "ALTER TABLE worker_config ADD COLUMN type TEXT DEFAULT 'apply'"); err != nil {
			return fail(err)
		}
	}
	revisions, err := columns(ctx, executor, "worker_config_revision")
	if err != nil {
		return fail(err)
	}
	if !revisions["drift_from"] {
		if _, err := executor.ExecContext(ctx, "ALTER TABLE worker_config_revision ADD COLUMN drift_from TEXT"); err != nil {
			return fail(err)
		}
	}
	return tx, nil
}

func columns(ctx context.Context, executor sqlExecutor, table string) (map[string]bool, error) {
	rows, err := executor.QueryContext(ctx, "PRAGMA table_info("+table+")")
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	result := make(map[string]bool)
	for rows.Next() {
		var cid, notNull, primaryKey int
		var name, columnType string
		var defaultValue any
		if err := rows.Scan(&cid, &name, &columnType, &notNull, &defaultValue, &primaryKey); err != nil {
			return nil, err
		}
		result[name] = true
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("table_info %s: %w", table, err)
	}
	return result, nil
}
