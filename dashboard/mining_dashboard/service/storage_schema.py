import os
import sqlite3

from mining_dashboard.config.config import (
    HASHRATE_WINDOW_COLUMNS,
    HISTORY_RETENTION_SEC,
)

from mining_dashboard.service.telemetry_store import (  # noqa: F401 — re-export
    NETWORK_HISTORY_RETENTION_SEC,
    XVB_HISTORY_RETENTION_SEC,
    TelemetryStoreMixin,
)

from mining_dashboard.service.workers.worker_config_store import (  # noqa: F401
    _RECONCILE_TERMINAL,
    WorkerConfigStoreMixin,
)

_BASE_HISTORY_COLS = {"v_p2pool", "v_xvb"}
_WINDOW_EXTRA_COLUMNS = [
    col
    for pair in HASHRATE_WINDOW_COLUMNS.values()
    for col in pair
    if col not in _BASE_HISTORY_COLS
]

_CORRUPTION_MARKERS = ("malformed", "not a database", "image is malformed", "file is encrypted")
_CORRUPT_KEEP = 3

WORKER_HISTORY_RETENTION_SEC = HISTORY_RETENTION_SEC

RAFFLE_WINS_MAX_ROWS = 5000

_TELEMETRY_TABLES = ("blocks", "xvb_history", "network_history", "disk_growth", "worker_history")


class StorageSchemaMixin:
    def _apply_schema(self):
        self._conn.execute("PRAGMA journal_mode=WAL")
        self._conn.execute("PRAGMA synchronous=NORMAL")
        with self._conn:
            self._create_tables()
            self._migrate_db()
            self._create_indexes()

    def _init_db(self):
        try:
            with self._db_lock:
                self._check_integrity()
                self._apply_schema()
        except sqlite3.Error as e:
            if self._is_corruption_error(e):
                self._recover_corrupt_db(f"startup: {e}")
            else:
                self._db_error("DB Init Error", e)

    @staticmethod
    def _is_corruption_error(e: Exception) -> bool:
        text = str(e).lower()
        return any(marker in text for marker in _CORRUPTION_MARKERS)

    def _check_integrity(self):
        row = self._conn.execute("PRAGMA integrity_check").fetchone()
        result = (row[0] if row else "") or ""
        if result != "ok":
            raise sqlite3.DatabaseError(
                f"integrity_check reported the database is malformed: {result}"
            )

    def _prune_quarantined(self) -> None:
        directory = os.path.dirname(self.db_path) or "."
        base = os.path.basename(self.db_path) + ".corrupt-"
        try:
            stale = sorted(f for f in os.listdir(directory) if f.startswith(base))
        except OSError:
            return
        for name in stale[: max(0, len(stale) - _CORRUPT_KEEP)]:
            try:
                os.remove(os.path.join(directory, name))
            except OSError:
                pass

    def _create_tables(self):
        extra = "".join(f", {c} REAL DEFAULT 0" for c in _WINDOW_EXTRA_COLUMNS)
        self._conn.execute(
            f"CREATE TABLE IF NOT EXISTS history (t TEXT, v REAL, v_p2pool REAL, v_xvb REAL, timestamp REAL{extra})"
        )
        self._conn.execute("CREATE TABLE IF NOT EXISTS kv_store (key TEXT PRIMARY KEY, value TEXT)")
        self._conn.execute(
            "CREATE TABLE IF NOT EXISTS shares (ts REAL PRIMARY KEY, difficulty REAL)"
        )
        self._conn.execute("CREATE TABLE IF NOT EXISTS events (ts REAL, type TEXT, detail TEXT)")
        self._conn.execute(
            "CREATE TABLE IF NOT EXISTS share_stats "
            "(ts REAL, accepted INTEGER, rejected INTEGER, invalid INTEGER, expired INTEGER)"
        )
        self._create_payouts_table()
        self._conn.execute(
            "CREATE TABLE IF NOT EXISTS worker_config "
            "(id INTEGER PRIMARY KEY AUTOINCREMENT, worker TEXT, change_id TEXT, ts REAL, "
            "status TEXT, changes TEXT, reason TEXT, type TEXT DEFAULT 'apply')"
        )
        self._conn.execute(
            "CREATE TABLE IF NOT EXISTS blocks (ts REAL, height INTEGER, difficulty REAL)"
        )
        self._conn.execute(
            "CREATE TABLE IF NOT EXISTS raffle_wins "
            "(block_id TEXT PRIMARY KEY, ts REAL, hashrate REAL, height INTEGER, tier TEXT)"
        )
        self._conn.execute(
            "CREATE TABLE IF NOT EXISTS xvb_history "
            "(ts REAL, avg_1h REAL, avg_24h REAL, fail_count INTEGER, "
            "donation_fraction REAL, mode TEXT)"
        )
        self._conn.execute(
            "CREATE TABLE IF NOT EXISTS network_history "
            "(ts REAL, difficulty REAL, height INTEGER, reward REAL, pool_hashrate REAL)"
        )
        self._conn.execute(
            "CREATE TABLE IF NOT EXISTS disk_growth "
            "(ts REAL, monero_db_bytes INTEGER, disk_used_gb REAL, disk_total_gb REAL)"
        )
        self._conn.execute(
            "CREATE TABLE IF NOT EXISTS worker_history "
            "(ts REAL, name TEXT, h15 REAL, accepted INTEGER, rejected INTEGER)"
        )
        self._conn.execute(
            "CREATE TABLE IF NOT EXISTS audit_events "
            "(id TEXT PRIMARY KEY, ts TEXT, source TEXT, actor TEXT, action TEXT, status TEXT, "
            "keys TEXT)"
        )
        self._conn.execute(
            "CREATE TABLE IF NOT EXISTS worker_config_revision (worker TEXT PRIMARY KEY, "
            "revision TEXT, last_change_id TEXT, ts REAL, drift_from TEXT, rigforge_version TEXT)"
        )
        self._conn.execute(
            "CREATE TABLE IF NOT EXISTS event_log "
            "(id INTEGER PRIMARY KEY AUTOINCREMENT, ts REAL NOT NULL, end_ts REAL, "
            "count INTEGER NOT NULL DEFAULT 1, kind TEXT NOT NULL, subject TEXT NOT NULL, "
            "label TEXT, severity TEXT NOT NULL, text TEXT NOT NULL)"
        )

    def _create_indexes(self):
        self._conn.execute("CREATE INDEX IF NOT EXISTS idx_ts ON history(timestamp)")
        self._conn.execute("CREATE INDEX IF NOT EXISTS idx_share_ts ON shares(ts)")
        self._conn.execute("CREATE INDEX IF NOT EXISTS idx_share_stats_ts ON share_stats(ts)")
        self._conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_worker_config ON worker_config(worker, ts)"
        )
        self._conn.execute("CREATE INDEX IF NOT EXISTS idx_blocks_ts ON blocks(ts)")
        self._conn.execute("CREATE INDEX IF NOT EXISTS idx_xvb_history_ts ON xvb_history(ts)")
        self._conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_network_history_ts ON network_history(ts)"
        )
        self._conn.execute("CREATE INDEX IF NOT EXISTS idx_disk_growth_ts ON disk_growth(ts)")
        self._conn.execute("CREATE INDEX IF NOT EXISTS idx_worker_history_ts ON worker_history(ts)")
        self._conn.execute("CREATE INDEX IF NOT EXISTS idx_audit_events_ts ON audit_events(ts)")
        self._conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_event_log_kind_subject_ts "
            "ON event_log(kind, subject, end_ts, ts)"
        )

    def _create_payouts_table(self):
        self._conn.execute(
            "CREATE TABLE IF NOT EXISTS payouts "
            "(chain TEXT, wallet_id TEXT NOT NULL, txid TEXT, height INTEGER, ts REAL, "
            "amount_atomic INTEGER, PRIMARY KEY (chain, wallet_id, txid))"
        )

    def _migrate_payout_identity(self, cursor):
        cursor.execute("PRAGMA table_info(payouts)")
        if "wallet_id" in {info[1] for info in cursor.fetchall()}:
            return
        self._conn.execute("SAVEPOINT payout_identity")
        try:
            self._conn.execute("ALTER TABLE payouts RENAME TO payouts_legacy")
            self._create_payouts_table()
            self._conn.execute(
                "INSERT INTO payouts (chain, wallet_id, txid, height, ts, amount_atomic) "
                "SELECT chain, 'unknown', txid, height, ts, amount_atomic FROM payouts_legacy"
            )
            self._conn.execute("DROP TABLE payouts_legacy")
        except sqlite3.Error:
            self._conn.execute("ROLLBACK TO payout_identity")
            raise
        finally:
            self._conn.execute("RELEASE payout_identity")

    def _migrate_db(self):
        cursor = self._conn.cursor()
        self._migrate_payout_identity(cursor)

        cursor.execute("PRAGMA table_info(history)")
        columns = {info[1] for info in cursor.fetchall()}

        if "v_p2pool" not in columns:
            self.logger.info("Migrating DB: Adding v_p2pool column to history")
            self._conn.execute("ALTER TABLE history ADD COLUMN v_p2pool REAL DEFAULT 0")

        if "v_xvb" not in columns:
            self.logger.info("Migrating DB: Adding v_xvb column to history")
            self._conn.execute("ALTER TABLE history ADD COLUMN v_xvb REAL DEFAULT 0")

        if "timestamp" not in columns:
            self.logger.info("Migrating DB: Adding timestamp column to history")
            self._conn.execute("ALTER TABLE history ADD COLUMN timestamp REAL")
            self._conn.execute(
                "UPDATE history SET timestamp = CAST(strftime('%s', t) AS REAL) WHERE timestamp IS NULL"
            )
            self._conn.execute("UPDATE history SET timestamp = 0 WHERE timestamp IS NULL")

        for col in _WINDOW_EXTRA_COLUMNS:
            if col not in columns:
                self.logger.info(f"Migrating DB: Adding {col} column to history")
                self._conn.execute(f"ALTER TABLE history ADD COLUMN {col} REAL DEFAULT 0")

        self._conn.execute("DROP TABLE IF EXISTS workers")

        cursor.execute("PRAGMA table_info(worker_config)")
        if "type" not in {info[1] for info in cursor.fetchall()}:
            self.logger.info("Migrating DB: Adding type column to worker_config")
            self._conn.execute("ALTER TABLE worker_config ADD COLUMN type TEXT DEFAULT 'apply'")
        self._migrate_worker_config_revision(cursor)
