import os
import sqlite3

from mining_dashboard.config.config import (
    HASHRATE_WINDOW_COLUMNS,
    HISTORY_RETENTION_SEC,
)

# The append-only telemetry series lives in telemetry_store.py (#1369) — a MIXIN, so StateManager
# below keeps one DB handle, one lock and one transaction scope. Both retention constants are
# re-exported here rather than merely moved: `storage_service.XVB_HISTORY_RETENTION_SEC` and
# `...NETWORK_HISTORY_RETENTION_SEC` were public module attributes before the split and importers
# (tests included) bind them from this module, so the import surface must not change.
from mining_dashboard.service.telemetry_store import (  # noqa: F401 — re-export, see above
    NETWORK_HISTORY_RETENTION_SEC,
    XVB_HISTORY_RETENTION_SEC,
    TelemetryStoreMixin,
)

# The `worker_config` accessors live in worker_config_store.py (#1369) — a MIXIN on the same
# terms, taken to make room for #1369's exact-id lookup once this file reached its budget ceiling.
# `_RECONCILE_TERMINAL` moved with `reconcile_worker_config_status`, its only reader, and is
# re-exported here for the same reason the retention constants above are: it was a module
# attribute of THIS module before the split and a test binds it from here.
from mining_dashboard.service.workers.worker_config_store import (  # noqa: F401 — re-export, see above
    _RECONCILE_TERMINAL,
    WorkerConfigStoreMixin,
)

# The 10m window reuses the original v_p2pool/v_xvb pair; every other window in
# HASHRATE_WINDOW_COLUMNS gets its own additive history column (#168). This flat, insertion-ordered
# list drives the CREATE, the migration, the INSERT, and the SELECT so they can never drift apart.
_BASE_HISTORY_COLS = {"v_p2pool", "v_xvb"}
_WINDOW_EXTRA_COLUMNS = [
    col
    for pair in HASHRATE_WINDOW_COLUMNS.values()
    for col in pair
    if col not in _BASE_HISTORY_COLS
]

# Substrings SQLite uses when the DB file itself is unusable — a corrupted page, a truncated/rewritten
# file, or a non-DB where the DB should be (#489). Matched case-insensitively against the error text
# so an operations-eating corruption auto-heals (quarantine + fresh DB) instead of erroring on every
# write cycle forever. A transient error (locked, disk full, permissions) is NOT here: those are the
# db_unhealthy path — retryable, not a reason to throw away history.
_CORRUPTION_MARKERS = ("malformed", "not a database", "image is malformed", "file is encrypted")
# How many quarantined copies of a corrupt DB to keep for post-mortem before pruning the oldest.
_CORRUPT_KEEP = 3

# v1.7 telemetry backbone retention (#196 Wave-0 proposal). blocks is permanent (no pruning — a
# small table, like payouts); worker_history extends the existing 30-day HISTORY_RETENTION_SEC
# convention. Each table gets its OWN retention (independent of `history`'s), by design. The
# xvb_history and network_history retentions moved to telemetry_store.py with the only writers
# that apply them (#1369), and are re-exported from the import block above.
WORKER_HISTORY_RETENTION_SEC = HISTORY_RETENTION_SEC  # 30 days

# raffle_wins is permanent-in-practice like payouts, but its rows are mirrored from an UNTRUSTED
# public file (see client/xvb_client.parse_winners), so it is bounded by row count instead of
# unbounded: keep the newest N. Decades of legit wins fit; a hostile feed cannot grow it past this.
RAFFLE_WINS_MAX_ROWS = 5000

# Table names carrying a per-table write-health signal (see get_table_health / _table_write_ok).
# It stays HERE and stays a plain name list: __init__ is its only reader, it seeds a dict of
# health entries from it, and it never dispatches into a method — so the three tables whose
# writers moved to telemetry_store.py (#1369) need no indirection back out of this module.
_TELEMETRY_TABLES = ("blocks", "xvb_history", "network_history", "disk_growth", "worker_history")


class StorageSchemaMixin:
    def _apply_schema(self):
        """Set pragmas + create/migrate the schema on the open connection. Caller holds ``_db_lock``.

        Split out of ``_init_db`` so the recovery path (#489) can rebuild the schema on a freshly
        reconnected DB without re-entering the (non-reentrant) lock via ``_init_db``."""
        # Enable WAL mode for better concurrency
        self._conn.execute("PRAGMA journal_mode=WAL")
        self._conn.execute("PRAGMA synchronous=NORMAL")
        with self._conn:
            self._create_tables()
            self._migrate_db()
            # Indexes come AFTER migration: idx_ts is on history(timestamp), a column
            # _migrate_db adds when upgrading a pre-timestamp DB. Creating it in
            # _create_tables would throw "no such column: timestamp" on that old schema
            # and abort the whole migration, leaving the DB half-upgraded.
            self._create_indexes()

    def _init_db(self):
        """Initializes the SQLite database schema and handles migrations.

        Runs an integrity check first (#489): a DB corrupted while the dashboard was down would
        otherwise fail on the first write and error every cycle thereafter. A malformed DB — caught by
        the check or by a corruption error while applying the schema — is quarantined and rebuilt fresh
        rather than left broken."""
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
        """True when the error means the DB file itself is unusable (vs. a retryable write failure)."""
        text = str(e).lower()
        return any(marker in text for marker in _CORRUPTION_MARKERS)

    def _check_integrity(self):
        """Raise ``sqlite3.DatabaseError`` if ``PRAGMA integrity_check`` doesn't return ``ok``.

        A DB can be malformed yet still open and answer simple queries, so this surfaces corruption
        proactively at startup. ``:memory:`` and a brand-new empty file both report ``ok``. Caller
        holds ``_db_lock``."""
        row = self._conn.execute("PRAGMA integrity_check").fetchone()
        result = (row[0] if row else "") or ""
        if result != "ok":
            # Phrase it with a corruption marker so _is_corruption_error routes it to recovery.
            raise sqlite3.DatabaseError(
                f"integrity_check reported the database is malformed: {result}"
            )

    def _prune_quarantined(self) -> None:
        """Keep only the newest ``_CORRUPT_KEEP`` ``<db>.corrupt-*`` files; delete older ones."""
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
        """Creates necessary tables if they don't exist."""
        # Per-window hashrate columns (#168) are appended so a fresh DB starts with them; existing
        # DBs get them via _migrate_db. Same source list (_WINDOW_EXTRA_COLUMNS) for both paths.
        extra = "".join(f", {c} REAL DEFAULT 0" for c in _WINDOW_EXTRA_COLUMNS)
        self._conn.execute(
            f"CREATE TABLE IF NOT EXISTS history (t TEXT, v REAL, v_p2pool REAL, v_xvb REAL, timestamp REAL{extra})"
        )
        self._conn.execute("CREATE TABLE IF NOT EXISTS kv_store (key TEXT PRIMARY KEY, value TEXT)")
        self._conn.execute(
            "CREATE TABLE IF NOT EXISTS shares (ts REAL PRIMARY KEY, difficulty REAL)"
        )
        # Degradation / recovery event markers for the chart (#99). No PK — two events can share a
        # timestamp; type is "hashrate_loss"|"hashrate_recovered"|... and detail is the tooltip text.
        self._conn.execute("CREATE TABLE IF NOT EXISTS events (ts REAL, type TEXT, detail TEXT)")
        # Pool-wide share-health deltas per poll (#116): what the proxy's cumulative counters
        # gained since the previous poll, never the counters themselves — so a proxy restart
        # re-baselines instead of poisoning the series. No PK — it's a rate series, duplicate
        # timestamps are harmless. Additive table, mirroring events: no _migrate_db change needed.
        self._conn.execute(
            "CREATE TABLE IF NOT EXISTS share_stats "
            "(ts REAL, accepted INTEGER, rejected INTEGER, invalid INTEGER, expired INTEGER)"
        )
        # Confirmed on-chain payouts from the view-only wallet (#381). Keyed (chain, txid) — NOT
        # txid alone — so the Tari sibling (#462) reuses this exact table with chain="tari"; the
        # payout_confirmed alert carries the chain too. Additive, forward-only: mirrors events /
        # share_stats, so no _migrate_db change is needed. amount_atomic keeps the wallet's native
        # atomic units; the view layer converts to XMR at the edge.
        self._conn.execute(
            "CREATE TABLE IF NOT EXISTS payouts "
            "(chain TEXT, txid TEXT, height INTEGER, ts REAL, amount_atomic INTEGER, "
            "PRIMARY KEY (chain, txid))"
        )
        # Per-worker config-change history for the Worker Inspect page (#185). RigForge keeps no
        # config history on the rig, so Pithead owns it: one row per change the dashboard applied,
        # with the writable-key `changes` we sent (each row IS a diff from the prior state, by
        # construction — we only ever record deltas we authored) and the rig's terminal outcome.
        # `changes` holds writable allowlist keys only, but `pools` carries `pass`, so #1543 strips
        # it on write and read. change_id is the rig's 16-hex id, or NULL for a request that never
        # reached a rig (rejected host-side). `type` distinguishes a config apply from a one-click
        # rig upgrade (#1014) — an upgrade's `changes` carries `{"version": ...}` instead of a
        # writable-key diff, and get_last_applied_worker_config must never merge that into the
        # config-editor prefill. New column, existing installs migrated in _migrate_db (below).
        self._conn.execute(
            "CREATE TABLE IF NOT EXISTS worker_config "
            "(id INTEGER PRIMARY KEY AUTOINCREMENT, worker TEXT, change_id TEXT, ts REAL, "
            "status TEXT, changes TEXT, reason TEXT, type TEXT DEFAULT 'apply')"
        )
        # v1.7 telemetry backbone (#196 Wave-0 proposal): five independent, additive time-series
        # tables. Each has its own retention (see the RETENTION_SEC constants above) and is
        # DB-only — nothing reads any of them per-cycle, so there's no in-memory mirror to keep in
        # sync (keeps RAM flat). No new columns on `history` — that's the whole point of dedicated
        # tables: independent retention, no row multiplication. Additive, forward-only, same as
        # payouts/worker_config above: no _migrate_db entry needed.
        #
        # blocks: pool block-found events. Permanent (no pruning — a handful of rows/week, like
        # payouts). `difficulty` is the Monero network difficulty AT DETECTION time (p2pool
        # exposes no per-block effort figure), so effort-per-block is derivable later.
        self._conn.execute(
            "CREATE TABLE IF NOT EXISTS blocks (ts REAL, height INTEGER, difficulty REAL)"
        )
        # raffle_wins: rounds THIS wallet won in the XvB raffle, mirrored from XvB's public
        # winners file (client/xvb_client.parse_winners). Permanent in practice (wins are rare,
        # like payouts) but bounded to the newest RAFFLE_WINS_MAX_ROWS because the source file
        # is untrusted (security review). Idempotent on block_id (the won round's block
        # identifier), so re-reading the ~4-day window the file covers never duplicates a win.
        # Additive, forward-only, same as payouts: no _migrate_db entry needed.
        self._conn.execute(
            "CREATE TABLE IF NOT EXISTS raffle_wins "
            "(block_id TEXT PRIMARY KEY, ts REAL, hashrate REAL, height INTEGER, tier TEXT)"
        )
        # xvb_history: XvB scalars sampled ~5 min wall-clock. 30-day retention.
        self._conn.execute(
            "CREATE TABLE IF NOT EXISTS xvb_history "
            "(ts REAL, avg_1h REAL, avg_24h REAL, fail_count INTEGER, "
            "donation_fraction REAL, mode TEXT)"
        )
        # network_history: Monero network difficulty/height/reward + the pool's own hashrate,
        # sampled hourly wall-clock. 90-day retention.
        self._conn.execute(
            "CREATE TABLE IF NOT EXISTS network_history "
            "(ts REAL, difficulty REAL, height INTEGER, reward REAL, pool_hashrate REAL)"
        )
        # disk_growth: monerod's on-disk DB size + host disk usage, sampled hourly wall-clock.
        # Permanent (no pruning — tiny, ~24 rows/day; it's a capacity trend line).
        self._conn.execute(
            "CREATE TABLE IF NOT EXISTS disk_growth "
            "(ts REAL, monero_db_bytes INTEGER, disk_used_gb REAL, disk_total_gb REAL)"
        )
        # worker_history: per-rig hashrate window + cumulative accepted/rejected, sampled ~5 min
        # wall-clock and written in one batched executemany call per cycle. 30-day retention.
        self._conn.execute(
            "CREATE TABLE IF NOT EXISTS worker_history "
            "(ts REAL, name TEXT, h15 REAL, accepted INTEGER, rejected INTEGER)"
        )
        # audit_events (#530): the durable backing store for the Security panel's audit trail. The
        # #33 control.log is host-owned, read-only from this container, and the writers already trim
        # it — so it can't back a month-level drill-down on its own. This table mirrors each
        # control.log row (source="control", `id` reused as the primary key — INSERT OR IGNORE makes
        # the mirror idempotent) AND the three kinds this dashboard detects itself: "host-edit"
        # (config.json changed with no matching commit), "rig-edit" (an apply outcome carrying an
        # unissued change_id) and "rig-drift" (#1551 — a revision moved with no new change_id); the
        # last two read the unauthenticated worker feed and SHARE one #724 per-worker flood cap.
        # `keys` is names only — never a value — the same contract as control.log itself.
        # Permanent, no pruning, like blocks/payouts/disk_growth: these are human-paced admin events,
        # not a hot metrics series.
        self._conn.execute(
            "CREATE TABLE IF NOT EXISTS audit_events "
            "(id TEXT PRIMARY KEY, ts TEXT, source TEXT, actor TEXT, action TEXT, status TEXT, "
            "keys TEXT)"
        )
        # The config revision each rig was last OBSERVED serving (#1551), one row per worker, plus
        # the revision it drifted FROM while that drift is still current (#1564, migrated below).
        # The PRIMARY KEY is the only index it wants. Holding the rig's opaque `revision` NEXT TO
        # the `last_change_id` beside it is the point: a later poll tells a recorded change (both
        # moved) from an edit underneath RigForge (only the revision moved) — #1542's open door.
        self._conn.execute(
            "CREATE TABLE IF NOT EXISTS worker_config_revision (worker TEXT PRIMARY KEY, "
            "revision TEXT, last_change_id TEXT, ts REAL, drift_from TEXT)"
        )

    def _create_indexes(self):
        """Creates indexes. Called after migrations so the indexed columns are guaranteed to
        exist even on a database created by an older schema version."""
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

    def _migrate_db(self):
        """Handles schema migrations for existing databases."""
        cursor = self._conn.cursor()

        # History Table Migrations
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

        # Per-window hashrate columns (#168) — additive, forward-only. Pre-existing rows keep DEFAULT
        # 0 (no per-window data was captured before this version); the chart signposts that.
        for col in _WINDOW_EXTRA_COLUMNS:
            if col not in columns:
                self.logger.info(f"Migrating DB: Adding {col} column to history")
                self._conn.execute(f"ALTER TABLE history ADD COLUMN {col} REAL DEFAULT 0")

        # Drop the orphaned `workers` table (#144). It backed the known_workers persistence layer,
        # which was dead code — the worker list is sourced live from the xmrig-proxy. Tidies old
        # DBs; harmless no-op on fresh ones.
        self._conn.execute("DROP TABLE IF EXISTS workers")

        # worker_config.type (#1014): every pre-existing row was written before rig upgrades were
        # recorded at all, so it was necessarily a config apply — backfill 'apply', matching the
        # column's own DEFAULT for any row a future ALTER-less write path might still hit.
        cursor.execute("PRAGMA table_info(worker_config)")
        if "type" not in {info[1] for info in cursor.fetchall()}:
            self.logger.info("Migrating DB: Adding type column to worker_config")
            self._conn.execute("ALTER TABLE worker_config ADD COLUMN type TEXT DEFAULT 'apply'")
        self._migrate_worker_config_revision(cursor)
