import json
import logging
import os
import random
import sqlite3
import threading
import time
from collections import deque
from typing import Any

from mining_dashboard.config.config import (
    DB_FILE_PATH,
    HASHRATE_WINDOW_COLUMNS,
    HISTORY_RETENTION_SEC,
    TIER_DEFAULTS,
)
from mining_dashboard.service.mining_store import MiningStoreMixin
from mining_dashboard.service.storage_schema import StorageSchemaMixin

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


class StateManager(
    StorageSchemaMixin, MiningStoreMixin, TelemetryStoreMixin, WorkerConfigStoreMixin
):
    """
    Manages persistent application state including hashrate history and mining mode statistics.

    Handles atomic file I/O to prevent data corruption and ensures state consistency
    across application restarts.
    """

    def __init__(self, db_path: str = None):
        self.logger = logging.getLogger("StateManager")
        # Default to the configured path; tests inject a temp file or ":memory:".
        self.db_path = db_path if db_path is not None else DB_FILE_PATH
        self._lock = threading.Lock()
        self._db_lock = threading.Lock()  # Lock for serializing DB access
        self.state = {
            "hashrate_history": deque(),
            "shares": [],
            "events": [],  # degradation / recovery markers for the chart (#99)
            "share_stats": [],  # per-poll accepted/rejected/invalid/expired deltas (#116)
            "xvb": {
                "total_donated_time": 0.0,
                "current_mode": "P2POOL",
                "avg_24h": 0.0,
                "avg_1h": 0.0,
                "fail_count": 0,
                "last_update": 0.0,
                # Unix ts of the last successful XvB raffle registration (#263); 0.0 until the
                # wallet is first auto-registered. Lets the UI show "Registered with XvB ✓".
                "registered_at": 0.0,
                # Registration status for the dashboard badge (#263): "" (pending), "registered",
                # "invalid" (endpoint rejected the wallet), or "failing" (endpoint erroring).
                "registration_state": "",
                # Fraction of the current cycle routed to XvB, written by the
                # controller each cycle. Lets the dashboard show what we *send*
                # (routed) next to what XvB *credits* (avg_1h/24h) — the live
                # credit-factor signal (Issue #70).
                "donation_fraction": 0.0,
                # The controller's own last-COMMANDED donation fraction — the closed-loop
                # integrator state (AlgoService.donation_fraction), distinct from the routed
                # fraction above. Persisted so a restart resumes the warmed-up split instead of
                # re-seeding cold from the feedforward estimate, and so a backup stack can hand it
                # off on failover (#249). 0.0 until the controller first steers.
                "commanded_fraction": 0.0,
            },
            # Initialize state with default values from configuration
            "tiers": TIER_DEFAULTS.copy(),
        }

        # XvB's published per-tier expected rewards (#118), fetched over Tor each cycle. Kept in
        # memory only (NOT the DB): it's re-fetched constantly and derived from an external file, so
        # losing it on restart just costs one refetch. ``last_update`` bumps only on a genuine fetch,
        # so the same staleness check as the stats (``xvb_stats_are_stale``) applies to it (#311).
        self._xvb_rewards = {"estimates": {}, "last_update": 0.0}
        # All-rounds aggregate from the same winners file (#866/#872): round-type frequencies +
        # qualifier counts. Same memory-only, refetch-on-restart, staleness-by-last_update rules.
        self._xvb_round_stats = {"stats": {}, "last_update": 0.0}

        # Initialize persistent DB connection
        # check_same_thread=False allows the connection to be used by multiple threads
        # (serialized via self._db_lock)
        # Persistence-health flag (#131): flipped False on any init/write failure so /api/state can
        # surface "history isn't being saved" instead of silently losing everything on the next restart.
        self.db_healthy = True

        # DB self-heal (#489): a corrupt DB used to error on every write forever, silently losing all
        # telemetry (and the DB now holds XvB-credited + payout state). On integrity loss we quarantine
        # the bad file and start fresh. ``db_reset_count`` is a monotonic one-shot the alerter edges on
        # so the operator is told history was reset (a plain db_healthy flip can be missed — a startup
        # reset has no prior state, a runtime reset flips back to healthy within one cycle).
        self.db_reset_count = 0
        self.last_db_reset = (
            None  # {"ts", "reason", "quarantine"} of the most recent reset, for the alert
        )

        # True only when the auto-heal RECOVERY ITSELF just failed (disk full, permissions) —
        # distinct from ``db_healthy``, which also flips false on an ordinary transient write
        # error (a locked DB, a momentary I/O hiccup) that must never be treated as unrecoverable.
        # This is the narrow signal `dashboard.fail_closed` (#490) gates on: a DB that a corruption
        # was DETECTED for and whose rebuild then failed, not merely "a write failed once". Cleared
        # on the next recovery attempt that succeeds.
        self.db_unrecoverable = False

        # Per-table write health for the v1.7 telemetry backbone (#196 Wave-0), mirroring
        # db_healthy above but per table. RAW: these entries record write ATTEMPTS only and know
        # nothing about the handle, so a closed one leaves them all reading healthy — read through
        # get_table_health, which folds that in (#1615), never this dict directly.
        self.table_health = {n: {"healthy": True, "last_write": None} for n in _TELEMETRY_TABLES}

        self._conn = sqlite3.connect(self.db_path, timeout=30.0, check_same_thread=False)
        self._conn.row_factory = sqlite3.Row

        self._init_db()
        self.load()

    def update_history(
        self, hashrate: float, p2pool_hr: float = 0, xvb_hr: float = 0, windows=None
    ) -> None:
        """Appends a new hashrate data point to the history buffer.

        ``windows`` (Issue #168) is an optional ``{window: (p2pool_hr, xvb_hr)}`` mapping of the
        per-averaging-window splits (1m / 1h / 12h / 24h — the 10m window is the base
        ``p2pool_hr``/``xvb_hr`` pair above). Each is stored in its own column so the chart's window
        toggle can plot a true average per window; an omitted/unknown window defaults to 0.
        """
        # UTC on purpose, and the trailing Z says so. The epoch `ts` is what everything renders
        # from (the chart plots epoch ms and the browser localizes); this string is a human label
        # and the input to the legacy-row migration, whose sqlite strftime('%s', t) parses it AS
        # UTC — a local-time string there skews every migrated row by the container's offset.
        # Store UTC everywhere; localize only at display.
        t_str = time.strftime("%Y-%m-%d %H:%M:%SZ", time.gmtime())
        ts = time.time()

        try:
            v_val = round(float(hashrate), 2)
            v_p2p = round(float(p2pool_hr), 2)
            v_xvb = round(float(xvb_hr), 2)
        except (ValueError, TypeError):
            v_val, v_p2p, v_xvb = 0.0, 0.0, 0.0

        # Per-window splits -> their columns (#168). Default every extra column to 0, then fill the
        # windows we were handed; a bad value falls back to 0 rather than aborting the whole write.
        extra = {col: 0.0 for col in _WINDOW_EXTRA_COLUMNS}
        for win, split in (windows or {}).items():
            cols = HASHRATE_WINDOW_COLUMNS.get(win)
            if not cols:
                continue
            p_col, x_col = cols
            try:
                if p_col in extra:
                    extra[p_col] = round(float(split[0]), 2)
                if x_col in extra:
                    extra[x_col] = round(float(split[1]), 2)
            except (ValueError, TypeError, IndexError):
                pass

        with self._lock:
            # 1. Update In-Memory State
            self.state["hashrate_history"].append(
                {
                    "t": t_str,
                    "v": v_val,
                    "v_p2pool": v_p2p,
                    "v_xvb": v_xvb,
                    "timestamp": ts,
                    **extra,
                }
            )

            # Prune in-memory history to enforce retention policy
            cutoff = ts - HISTORY_RETENTION_SEC
            while (
                self.state["hashrate_history"]
                and self.state["hashrate_history"][0]["timestamp"] < cutoff
            ):
                self.state["hashrate_history"].popleft()

        # 2. Persist to DB
        try:
            with self._db_lock:
                if not self._conn:
                    return
                with self._conn:
                    cols = ["t", "v", "v_p2pool", "v_xvb", "timestamp"] + _WINDOW_EXTRA_COLUMNS
                    placeholders = ", ".join("?" * len(cols))
                    values = (t_str, v_val, v_p2p, v_xvb, ts) + tuple(
                        extra[c] for c in _WINDOW_EXTRA_COLUMNS
                    )
                    self._conn.execute(
                        # Column/placeholder lists are literals + a module constant, not user input.
                        f"INSERT INTO history ({', '.join(cols)}) VALUES ({placeholders})",  # noqa: S608
                        values,
                    )
                    # Prune old history from DB to prevent unbounded growth (Probabilistic pruning to save I/O)
                    if random.random() < 0.05:  # noqa: S311 — pruning sampler, not a security context
                        self._conn.execute(
                            "DELETE FROM history WHERE timestamp < ?", (ts - HISTORY_RETENTION_SEC,)
                        )
        except sqlite3.Error as e:
            self._db_error("History Update Error", e)

    def add_share(self, ts: float, difficulty: float) -> None:
        """Appends a new share to history and persists it to the DB."""
        with self._lock:
            # Check if share already exists to prevent duplicate in-memory appends
            if not any(s["ts"] == ts for s in self.state.get("shares", [])):
                self.state["shares"].append({"ts": ts, "difficulty": difficulty})

            # Prune in-memory state based on the 30-day config
            cutoff = time.time() - HISTORY_RETENTION_SEC
            self.state["shares"] = [s for s in self.state["shares"] if s["ts"] >= cutoff]

        # Persist to DB
        try:
            with self._db_lock:
                if not self._conn:
                    return
                with self._conn:
                    self._conn.execute(
                        "INSERT OR IGNORE INTO shares (ts, difficulty) VALUES (?, ?)",
                        (ts, difficulty),
                    )

                    if random.random() < 0.05:  # noqa: S311 — pruning sampler, not a security context
                        self._conn.execute(
                            "DELETE FROM shares WHERE ts < ?",
                            (time.time() - HISTORY_RETENTION_SEC,),
                        )
        except sqlite3.Error as e:
            self._db_error("Share Insert Error", e)

    def add_shares(self, count: int, latest_ts: float, difficulty: float):
        """Record `count` shares ending at `latest_ts`. P2Pool's stratum exposes a CUMULATIVE
        shares_found counter; the dashboard polls every UPDATE_INTERVAL (30s), so a burst of shares
        between polls advances last_share_found_time only once. Spread the count across distinct
        timestamps (the shares table is keyed by ts) so a higher-hashrate / nano-sidechain node's
        extra shares in one window aren't dropped (#129)."""
        if count <= 0:
            return
        for i in range(count):
            # Distinct timestamps ending at latest_ts (1 ms steps back) so the ts PRIMARY KEY keeps all.
            self.add_share(round(latest_ts - 0.001 * (count - 1 - i), 3), difficulty)

    def get_shares(self) -> list[dict[str, Any]]:
        """Returns a copy of the shares history."""
        with self._lock:
            return list(self.state.get("shares", []))

    def add_event(self, ts: float, event_type: str, detail: str = "") -> None:
        """Record a chart event marker (#99) — a degradation/recovery point the chart draws and the
        history window prunes, mirroring shares. Persisted so it survives a dashboard restart."""
        with self._lock:
            self.state.setdefault("events", []).append(
                {"ts": ts, "type": event_type, "detail": detail}
            )
            cutoff = time.time() - HISTORY_RETENTION_SEC
            self.state["events"] = [e for e in self.state["events"] if e["ts"] >= cutoff]
        try:
            with self._db_lock:
                if not self._conn:
                    return
                with self._conn:
                    self._conn.execute(
                        "INSERT INTO events (ts, type, detail) VALUES (?, ?, ?)",
                        (ts, event_type, detail),
                    )
                    if random.random() < 0.05:  # noqa: S311 — pruning sampler, not a security context
                        self._conn.execute(
                            "DELETE FROM events WHERE ts < ?",
                            (time.time() - HISTORY_RETENTION_SEC,),
                        )
        except sqlite3.Error as e:
            self._db_error("Event Insert Error", e)

    def get_events(self) -> list[dict[str, Any]]:
        """Returns a copy of the chart events (#99)."""
        with self._lock:
            return list(self.state.get("events", []))

    def add_share_stats(
        self, ts: float, accepted: int = 0, rejected: int = 0, invalid: int = 0, expired: int = 0
    ) -> None:
        """Record one poll's pool-wide share-health DELTAS (#116) — how much each cumulative
        proxy counter advanced since the previous poll — in memory and in the DB. Mirrors
        add_event: retention-pruned in memory, probabilistically pruned on disk."""
        row = {
            "ts": ts,
            "accepted": accepted,
            "rejected": rejected,
            "invalid": invalid,
            "expired": expired,
        }
        with self._lock:
            self.state.setdefault("share_stats", []).append(row)
            cutoff = time.time() - HISTORY_RETENTION_SEC
            self.state["share_stats"] = [s for s in self.state["share_stats"] if s["ts"] >= cutoff]
        try:
            with self._db_lock:
                if not self._conn:
                    return
                with self._conn:
                    self._conn.execute(
                        "INSERT INTO share_stats (ts, accepted, rejected, invalid, expired) "
                        "VALUES (?, ?, ?, ?, ?)",
                        (ts, accepted, rejected, invalid, expired),
                    )
                    if random.random() < 0.05:  # noqa: S311 — pruning sampler, not a security context
                        self._conn.execute(
                            "DELETE FROM share_stats WHERE ts < ?",
                            (time.time() - HISTORY_RETENTION_SEC,),
                        )
        except sqlite3.Error as e:
            self._db_error("Share Stats Insert Error", e)

    def get_share_stats(self) -> list[dict[str, Any]]:
        """Returns a copy of the per-poll share-health deltas (#116)."""
        with self._lock:
            return list(self.state.get("share_stats", []))

    def _recover_corrupt_db(self, reason: str):
        """Quarantine a corrupt DB file and rebuild an empty schema so persistence resumes (#489).

        The bad file is renamed to ``<db>.corrupt-<UTC>`` (kept for post-mortem, oldest pruned) rather
        than deleted, and a fresh DB takes its place. Bumps ``db_reset_count`` so the alerter tells the
        operator history was reset. A ``:memory:`` DB has no file to quarantine — it just rebuilds. On
        any failure here the DB stays flagged unhealthy (the #131 badge) rather than crashing."""
        stamp = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
        quarantine = None
        try:
            with self._db_lock:
                try:
                    if self._conn:
                        self._conn.close()
                except sqlite3.Error:
                    pass
                self._conn = None
                if self.db_path != ":memory:" and os.path.exists(self.db_path):
                    quarantine = f"{self.db_path}.corrupt-{stamp}"
                    os.replace(self.db_path, quarantine)
                    # WAL/SHM siblings of a corrupt DB are meaningless without it — drop them so the
                    # fresh DB doesn't inherit a stale write-ahead log.
                    for sfx in ("-wal", "-shm"):
                        try:
                            os.remove(self.db_path + sfx)
                        except OSError:
                            pass
                    self._prune_quarantined()
                self._conn = sqlite3.connect(self.db_path, timeout=30.0, check_same_thread=False)
                self._conn.row_factory = sqlite3.Row
                self._apply_schema()
            self.db_healthy = True
            self.db_unrecoverable = False  # a later successful attempt clears an earlier failure
            self.db_reset_count += 1
            self.last_db_reset = {"ts": time.time(), "reason": reason, "quarantine": quarantine}
            self.logger.error(
                "DB corruption recovered (%s): quarantined to %s, started a fresh database — "
                "hashrate history and stats before now were lost.",
                reason,
                quarantine or "(in-memory, nothing to quarantine)",
            )
        except (sqlite3.Error, OSError) as e:
            # Recovery itself failed (disk full, permissions) — this is the unrecoverable case
            # #490's fail-closed gate watches for, distinct from an ordinary transient write error.
            self.db_unrecoverable = True
            self._db_error("DB Recovery Error", e)

    def _db_error(self, where: str, e: Exception):
        """Record a DB failure and flag persistence as unhealthy so /api/state can surface it (#131).

        A corruption error (malformed file) triggers auto-recovery (#489) — quarantine + fresh DB —
        so a corrupt DB self-heals instead of erroring on every write cycle indefinitely. ``where ==
        "DB Recovery Error"`` is excluded so a failed recovery can't recurse."""
        self.db_healthy = False
        self.logger.error(f"{where}: {e}")
        if where != "DB Recovery Error" and self._is_corruption_error(e):
            self._recover_corrupt_db(f"{where}: {e}")

    def is_db_healthy(self) -> bool:
        """True unless a DB init or write has failed — drives the dashboard persistence badge (#131)."""
        return self.db_healthy

    def is_db_unrecoverable(self) -> bool:
        """True only when the auto-heal rebuild itself just failed (#489/#490) — narrower than
        ``is_db_healthy() is False``, which also covers an ordinary transient write error. Feeds
        `dashboard.fail_closed`'s miner hold; a transient blip must never trip it."""
        return self.db_unrecoverable

    def load(self) -> None:
        """
        Loads state from SQLite into memory on startup.
        """
        try:
            with self._db_lock:
                if not self._conn:
                    return
                cursor = self._conn.cursor()

                with self._lock:
                    # 1. Load History
                    # Limit to retention period to prevent memory bloat
                    history_cutoff = time.time() - HISTORY_RETENTION_SEC
                    hist_cols = ", ".join(
                        ["t", "v", "v_p2pool", "v_xvb", "timestamp"] + _WINDOW_EXTRA_COLUMNS
                    )
                    cursor.execute(
                        # Column list is literals + a module constant, never user input; value is ?-bound.
                        f"SELECT {hist_cols} FROM history WHERE timestamp > ? ORDER BY timestamp ASC",  # noqa: S608
                        (history_cutoff,),
                    )
                    history = []
                    for row in cursor.fetchall():
                        item = dict(row)
                        # Sanitize NULLs to ensure chart stability (the per-window columns are NULL on
                        # pre-#168 rows and 0 thereafter — both read as 0 for the chart).
                        item["v_p2pool"] = item.get("v_p2pool") or 0.0
                        item["v_xvb"] = item.get("v_xvb") or 0.0
                        for col in _WINDOW_EXTRA_COLUMNS:
                            item[col] = item.get(col) or 0.0
                        history.append(item)
                    self.state["hashrate_history"] = deque(history)

                    # 2. Load XVB Stats (KV Store)
                    cursor.execute("SELECT key, value FROM kv_store WHERE key LIKE 'xvb_%'")
                    for row in cursor.fetchall():
                        # The query filters to 'xvb_%', so every key carries the prefix; strip it.
                        key = row["key"][4:]

                        val = row["value"]

                        # Migration: Handle legacy keys from previous versions
                        if key == "1h_avg":
                            key = "avg_1h"
                        if key == "24h_avg":
                            key = "avg_24h"

                        # Enforce schema: Ignore keys not present in the default state
                        if key not in self.state["xvb"]:
                            continue

                        try:
                            # Dynamic type restoration based on default value type
                            default_val = self.state["xvb"][key]
                            if isinstance(default_val, bool):
                                val = val.lower() == "true"
                            elif isinstance(default_val, float):
                                val = float(val)
                            elif isinstance(default_val, int):
                                val = int(val)
                            self.state["xvb"][key] = val
                        except (ValueError, TypeError):
                            self.logger.warning(f"Skipping corrupted KV pair: {key}={val}")

                    # 3. Load Shares
                    cursor.execute(
                        "SELECT ts, difficulty FROM shares WHERE ts > ? ORDER BY ts ASC",
                        (history_cutoff,),
                    )
                    self.state["shares"] = [dict(row) for row in cursor.fetchall()]

                    # 4. Load chart events (#99) — the events table is additive, so guard against a
                    # pre-migration DB that predates it.
                    try:
                        cursor.execute(
                            "SELECT ts, type, detail FROM events WHERE ts > ? ORDER BY ts ASC",
                            (history_cutoff,),
                        )
                        self.state["events"] = [dict(row) for row in cursor.fetchall()]
                    except sqlite3.Error:
                        self.state["events"] = []

                    # 5. Load share-stat deltas (#116) — additive table, same pre-migration guard.
                    try:
                        cursor.execute(
                            "SELECT ts, accepted, rejected, invalid, expired FROM share_stats "
                            "WHERE ts > ? ORDER BY ts ASC",
                            (history_cutoff,),
                        )
                        self.state["share_stats"] = [dict(row) for row in cursor.fetchall()]
                    except sqlite3.Error:
                        self.state["share_stats"] = []

                self.logger.info(f"State successfully loaded from {self.db_path}")
        except sqlite3.Error as e:
            self.logger.error(f"DB Load Error: {e}")

    def _table_write_ok(self, table: str, ts: float):
        """Stamp a successful write for the v1.7 telemetry backbone's per-table health signal."""
        self.table_health[table] = {"healthy": True, "last_write": ts}

    def _table_write_failed(self, table: str, where: str, e: Exception):
        """Flip a table's health signal False and route through the shared #131/#489 error path
        (flags the global db_healthy badge too, and triggers corruption auto-recovery if that's
        what this was)."""
        self.table_health[table]["healthy"] = False
        self._db_error(where, e)

    def get_table_health(self) -> dict[str, dict[str, Any]]:
        """Per-table write health for the v1.7 telemetry backbone (#196): ``{table: {"healthy",
        "last_write"}}``. Lets a caller notice a capture hook that has silently stopped writing —
        the data-service poll loop is one big try/except, so nothing else would surface that. A
        closed handle drops every write at the guard before either stamp runs, so ``healthy`` is
        derived here (#1615) — no table reads healthy while there is no handle to write through."""
        live = bool(self._conn)  # the very test each writer's guard makes, not a re-spelling of it
        return {k: {**v, "healthy": v["healthy"] and live} for k, v in self.table_health.items()}

    def get_xvb_stats(self) -> dict[str, Any]:
        """Returns the current XvB mining statistics dictionary."""
        with self._lock:
            return self.state["xvb"].copy()

    def set_xvb_standby(self, standby: dict[str, Any]):
        """Store the XvB controller state last pulled from the PRIMARY stack (#249). Held as
        standby only — never folded into the live controller until this host takes over on
        failover, and never acted on while the primary is authoritative (this host has no workers
        then, so the controller stays on P2Pool regardless). Persisted (kv_store) so the standby
        survives a backup restart. A JSON blob, mirroring ``save_snapshot``."""
        try:
            self.set_kv("xvb_standby", json.dumps(standby))
        except (TypeError, ValueError) as e:
            self._db_error("XvB Standby Serialization Error", e)

    def get_xvb_standby(self) -> dict[str, Any] | None:
        """The last-pulled primary XvB controller state (#249), or None if a backup source was
        never configured / has not fetched yet. Inspectable via ``/api/state`` so an operator can
        confirm the backup is warm before a failover."""
        raw = self.get_kv("xvb_standby")
        if not raw:
            return None
        try:
            val = json.loads(raw)
            return val if isinstance(val, dict) else None
        except (json.JSONDecodeError, TypeError):
            return None

    def get_xvb_reward_estimates(self) -> dict[str, Any]:
        """The cached XvB per-tier reward estimates (#118): ``{"estimates": {...}, "last_update": ts}``."""
        with self._lock:
            return {
                "estimates": dict(self._xvb_rewards["estimates"]),
                "last_update": self._xvb_rewards["last_update"],
            }

    def set_xvb_reward_estimates(self, estimates: dict[str, float]):
        """Replace the cached reward estimates and stamp ``last_update`` (only on a genuine fetch, #118)."""
        with self._lock:
            self._xvb_rewards = {"estimates": dict(estimates or {}), "last_update": time.time()}

    def get_xvb_round_stats(self) -> dict[str, Any]:
        """The cached all-rounds raffle aggregate (#866/#872):
        ``{"stats": {"types": {...}, "span_days": d}, "last_update": ts}``."""
        with self._lock:
            return {
                "stats": dict(self._xvb_round_stats["stats"]),
                "last_update": self._xvb_round_stats["last_update"],
            }

    def set_xvb_round_stats(self, stats: dict[str, Any]):
        """Replace the cached round aggregate and stamp ``last_update`` (only on a genuine fetch)."""
        with self._lock:
            self._xvb_round_stats = {"stats": dict(stats or {}), "last_update": time.time()}

    def update_xvb_stats(
        self,
        mode: str | None = None,
        avg_24h: float | None = None,
        avg_1h: float | None = None,
        fail_count: int | None = None,
        **kwargs,
    ) -> None:
        """
        Updates specific fields within the XvB statistics state.

        Allows partial updates to decouple mode switching from statistical updates.

        Args:
            mode (str, optional): The current mining mode (e.g., "P2POOL", "XVB").
            avg_24h (float, optional): 24-hour average hashrate on XvB.
            avg_1h (float, optional): 1-hour average hashrate on XvB.
            fail_count (int, optional): Consecutive failure count for XvB endpoint.
            **kwargs: Updates for other keys in the xvb state (e.g., total_donated_time).
        """
        updates = {}
        with self._lock:
            if mode is not None:
                self.state["xvb"]["current_mode"] = mode
                updates["xvb_current_mode"] = mode

            # `last_update` is the "Stats fetched from xmrvsbeast.com (Updated: …)" timestamp, so it
            # must bump ONLY on a real fetch — never on the per-cycle local writes the algo controller
            # makes (mode, donation_fraction, fail_count). Otherwise the UI's "Updated" time ticks
            # fresh every cycle even while xmrvsbeast.com is unreachable, hiding stale data (#136). A
            # successful xvb_client.get_stats is the only source of avg_1h / avg_24h, so those — and
            # only those — mark a genuine fetch.
            fetched = False
            if avg_24h is not None:
                self.state["xvb"]["avg_24h"] = avg_24h
                updates["xvb_avg_24h"] = avg_24h
                fetched = True

            if avg_1h is not None:
                self.state["xvb"]["avg_1h"] = avg_1h
                updates["xvb_avg_1h"] = avg_1h
                fetched = True
            if fail_count is not None:
                self.state["xvb"]["fail_count"] = fail_count
                updates["xvb_fail_count"] = fail_count

            # Handle additional fields passed via kwargs (e.g., total_donated_time, donation_fraction).
            # These are local/derived writes, NOT a fetch, so they must not bump `last_update`.
            for k, v in kwargs.items():
                if k in self.state["xvb"] and k != "current_mode":
                    # Skip None values to prevent type corruption in DB (persisted as "None" string)
                    if v is None:
                        continue

                    # Enforce type consistency with initialized state to prevent runtime drift
                    default_val = self.state["xvb"][k]
                    try:
                        if isinstance(default_val, float):
                            v = float(v)
                        elif isinstance(default_val, int) and not isinstance(default_val, bool):
                            v = int(v)
                    except (ValueError, TypeError):
                        pass  # Keep original value if cast fails

                    self.state["xvb"][k] = v
                    updates[f"xvb_{k}"] = v

            # Bump the freshness timestamp only on a genuine xmrvsbeast.com fetch (#136).
            if fetched:
                ts = time.time()
                self.state["xvb"]["last_update"] = ts
                updates["xvb_last_update"] = ts

        # Persist to DB
        if updates:
            try:
                with self._db_lock:
                    if not self._conn:
                        return
                    with self._conn:
                        self._conn.executemany(
                            "INSERT OR REPLACE INTO kv_store (key, value) VALUES (?, ?)",
                            [(k, str(v)) for k, v in updates.items()],
                        )
            except sqlite3.Error as e:
                self._db_error("XVB Update Error", e)

    def get_kv(self, key: str) -> str | None:
        """Read one value from the kv_store, or None if absent / unreadable (#375)."""
        try:
            with self._db_lock:
                if not self._conn:
                    return None
                cursor = self._conn.cursor()
                cursor.execute("SELECT value FROM kv_store WHERE key = ?", (key,))
                row = cursor.fetchone()
                return row[0] if row else None
        except sqlite3.Error as e:
            self.logger.error(f"KV Read Error: {e}")
            return None

    def set_kv(self, key: str, value) -> None:
        """Insert-or-replace one kv_store value (#375). Values are stored as strings, mirroring
        the XvB stats writes above."""
        try:
            with self._db_lock:
                if not self._conn:
                    return
                with self._conn:
                    self._conn.execute(
                        "INSERT OR REPLACE INTO kv_store (key, value) VALUES (?, ?)",
                        (key, str(value)),
                    )
        except sqlite3.Error as e:
            self._db_error("KV Write Error", e)

    def save_snapshot(self, data: dict[str, Any]):
        """Persists the full application state snapshot to the KV store, through ``set_kv`` — one
        kv_store key like any other, where the hand-rolled INSERT was a second copy of that
        method's body. A failed write still reaches ``_db_error``; only its label changes."""
        if not data:
            return
        try:
            self.set_kv("snapshot_latest_data", json.dumps(data))
        except TypeError as e:
            # A non-serializable snapshot is a persistent write failure (data lost on restart),
            # so flag persistence unhealthy like every other write path — otherwise the #131
            # badge stays green while snapshots silently never persist.
            self._db_error("Snapshot Serialization Error", e)

    def load_snapshot(self) -> dict[str, Any] | None:
        """Loads the last persisted application state snapshot, through ``get_kv``. Absent key,
        empty value and failed read all reach the caller as ``None`` — what the hand-rolled read
        did too, since it treated a falsy ``row[0]`` as "no snapshot" rather than as a value."""
        raw = self.get_kv("snapshot_latest_data")
        if not raw:
            return None
        try:
            return json.loads(raw)
        except (json.JSONDecodeError, TypeError) as e:
            self.logger.error(f"Snapshot Load Error: {e}")
            return None

    def get_history(self) -> list[dict[str, Any]]:
        """Returns a copy of the hashrate history."""
        with self._lock:
            return list(self.state["hashrate_history"])

    def get_tiers(self) -> dict[str, Any]:
        """Returns a copy of the donation tiers configuration."""
        with self._lock:
            return self.state["tiers"].copy()

    def close(self):
        """Closes the database connection safely."""
        with self._db_lock:
            if self._conn:
                try:
                    self._conn.close()
                    self.logger.info("Database connection closed.")
                except sqlite3.Error as e:
                    self.logger.error(f"Error closing database: {e}")
                finally:
                    self._conn = None
