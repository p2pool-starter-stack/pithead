import bisect
import logging
import random
import sqlite3
import time
from typing import Any

from mining_dashboard.config.config import HISTORY_RETENTION_SEC

logger = logging.getLogger("StateManager")
WORKER_HISTORY_RETENTION_SEC = HISTORY_RETENTION_SEC
RAFFLE_WINS_MAX_ROWS = 5000


def _raffle_wins_max_rows():
    from mining_dashboard.service import storage_service

    return storage_service.RAFFLE_WINS_MAX_ROWS


class MiningStoreMixin:
    def add_payouts(self, chain: str, rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
        """Persist confirmed on-chain payouts (#381), idempotent on ``(chain, txid)``, and return
        only the rows that were NEWLY inserted this call.

        The returned "new" list is what drives the ``payout_confirmed`` alert: an already-stored
        payout is silently ignored (INSERT OR IGNORE), so a dashboard restart re-fetching the tip
        never re-alerts. Not held in memory (payouts are read straight from the DB by the view /
        alert paths) — unlike the retention-pruned series, payout history is small and permanent."""
        if not rows:
            return []
        new_rows = []
        try:
            with self._db_lock:
                if not self._conn:
                    return []
                with self._conn:
                    for r in rows:
                        cur = self._conn.execute(
                            "INSERT OR IGNORE INTO payouts "
                            "(chain, txid, height, ts, amount_atomic) VALUES (?, ?, ?, ?, ?)",
                            (
                                chain,
                                r["txid"],
                                int(r.get("height", 0) or 0),
                                float(r.get("ts", 0) or 0),
                                int(r.get("amount_atomic", 0) or 0),
                            ),
                        )
                        # rowcount == 1 means the row was actually inserted (not an ignored dup),
                        # so it's a genuinely new payout worth alerting on exactly once.
                        if cur.rowcount == 1:
                            new_rows.append(r)
        except (sqlite3.Error, KeyError, ValueError, TypeError) as e:
            self._db_error("Payout Insert Error", e)
            return []
        return new_rows

    def get_payouts(self, chain: str | None = None) -> list[dict[str, Any]]:
        """Return stored confirmed payouts, newest first. Filters to ``chain`` when given (the
        dashboard's Monero card reads chain="monero"); omit it for the cross-chain total."""
        try:
            with self._db_lock:
                if not self._conn:
                    return []
                cursor = self._conn.cursor()
                if chain is None:
                    cursor.execute(
                        "SELECT chain, txid, height, ts, amount_atomic FROM payouts "
                        "ORDER BY ts DESC"
                    )
                else:
                    cursor.execute(
                        "SELECT chain, txid, height, ts, amount_atomic FROM payouts "
                        "WHERE chain = ? ORDER BY ts DESC",
                        (chain,),
                    )
                return [dict(row) for row in cursor.fetchall()]
        except sqlite3.Error as e:
            self.logger.error(f"Payout Read Error: {e}")
            return []

    def get_payout_max_height(self, chain: str) -> int:
        """Highest stored block height for ``chain`` (0 if none) — the wallet-poll seed. Fetching
        transfers from this height forward re-scans only the tip; idempotent add_payouts drops the
        overlap, so a restart replays nothing (#381)."""
        try:
            with self._db_lock:
                if not self._conn:
                    return 0
                cursor = self._conn.cursor()
                cursor.execute("SELECT MAX(height) FROM payouts WHERE chain = ?", (chain,))
                row = cursor.fetchone()
                return int(row[0]) if row and row[0] is not None else 0
        except sqlite3.Error as e:
            self.logger.error(f"Payout Height Read Error: {e}")
            return 0

    def add_audit_event(
        self, id: str, ts: str, source: str, actor: str, action: str, status: str, keys: str
    ) -> None:
        """Store an audit row; a terminal control result replaces its same-id preview (#530).
        Deterministic host/rig edit ids stay first-write idempotent. Values never enter ``keys``."""
        try:
            with self._db_lock:
                if not self._conn:
                    return
                self._conn.execute(
                    "INSERT INTO audit_events "
                    "(id, ts, source, actor, action, status, keys) VALUES (?, ?, ?, ?, ?, ?, ?) "
                    "ON CONFLICT(id) DO UPDATE SET ts=excluded.ts, source=excluded.source, "
                    "actor=excluded.actor, action=excluded.action, status=excluded.status, keys=excluded.keys "
                    "WHERE excluded.source='control' AND audit_events.source='control'",
                    (id, ts, source, actor, action, status, keys),
                )
                self._conn.commit()
        except sqlite3.Error as e:
            self._db_error("Audit Event Write Error", e)

    def get_audit_events(self, limit: int = 1000) -> list[dict[str, Any]]:
        """Every persisted audit row (#530), newest first by ``ts`` — the merged, durable
        backing store for the Security panel's time-grouped view."""
        try:
            with self._db_lock:
                if not self._conn:
                    return []
                cursor = self._conn.cursor()
                cursor.execute(
                    "SELECT id, ts, source, actor, action, status, keys FROM audit_events "
                    "ORDER BY ts DESC LIMIT ?",
                    (limit,),
                )
                return [dict(row) for row in cursor.fetchall()]
        except sqlite3.Error as e:
            self.logger.error(f"Audit Event Read Error: {e}")
            return []

    def add_block(self, ts: float, height: int, difficulty: float) -> None:
        """Record one pool block-found event (#196): permanent (no retention prune — a handful of
        rows/week, like payouts). The caller (DataService) reuses `_shares_to_record` on p2pool's
        cumulative blocks_found counter so this fires exactly once per genuinely NEW block; a
        p2pool restart (counter goes backwards) re-baselines instead of replaying history."""
        try:
            with self._db_lock:
                if not self._conn:
                    return
                with self._conn:
                    self._conn.execute(
                        "INSERT INTO blocks (ts, height, difficulty) VALUES (?, ?, ?)",
                        (ts, height, difficulty),
                    )
            self._table_write_ok("blocks", ts)
        except sqlite3.Error as e:
            self._table_write_failed("blocks", "Block Insert Error", e)

    def get_blocks(self, since: float = 0.0) -> list[dict[str, Any]]:
        """Pool block-found events at or after `since` (default: all), oldest first."""
        try:
            with self._db_lock:
                if not self._conn:
                    return []
                cursor = self._conn.cursor()
                cursor.execute(
                    "SELECT ts, height, difficulty FROM blocks WHERE ts >= ? ORDER BY ts ASC",
                    (since,),
                )
                return [dict(row) for row in cursor.fetchall()]
        except sqlite3.Error as e:
            self.logger.error(f"Block Read Error: {e}")
            return []

    def add_raffle_wins(self, wins: list[dict[str, Any]]) -> list[dict[str, Any]]:
        """Persist XvB raffle wins mirrored from the public winners file, idempotent on
        ``block_id``, and return only the rows NEWLY inserted this call.

        Same contract as ``add_payouts``: the caller announces each returned win exactly once,
        and a dashboard restart re-reading the file's window is silently ignored (INSERT OR
        IGNORE), so a win is never re-announced. Not held in memory — the view reads straight
        from the DB, and win history is small and permanent."""
        if not wins:
            return []
        new_rows = []
        try:
            with self._db_lock:
                if not self._conn:
                    return []
                with self._conn:
                    for w in wins:
                        cur = self._conn.execute(
                            "INSERT OR IGNORE INTO raffle_wins "
                            "(block_id, ts, hashrate, height, tier) VALUES (?, ?, ?, ?, ?)",
                            (
                                w["block_id"],
                                float(w.get("ts", 0) or 0),
                                float(w.get("hashrate", 0) or 0),
                                int(w.get("height", 0) or 0),
                                w.get("tier", ""),
                            ),
                        )
                        # rowcount == 1 means the row was actually inserted (not an ignored
                        # dup), so it's a genuinely new win worth announcing exactly once.
                        if cur.rowcount == 1:
                            new_rows.append(w)
                    # Bound the table (security review): rows are mirrored from an UNTRUSTED
                    # public file and the masked wallet form is publicly derivable, so a
                    # hostile feed could otherwise grow this permanent table without limit.
                    # Legit wins can't approach the cap (hourly rounds — 5000 wins is decades
                    # of winning every other round), so the prune never touches real history.
                    self._conn.execute(
                        "DELETE FROM raffle_wins WHERE block_id NOT IN "
                        "(SELECT block_id FROM raffle_wins ORDER BY ts DESC LIMIT ?)",
                        (_raffle_wins_max_rows(),),
                    )
        except (sqlite3.Error, KeyError, ValueError, TypeError) as e:
            self._db_error("Raffle Win Insert Error", e)
            return []
        return new_rows

    def get_raffle_wins(self, since: float = 0.0) -> list[dict[str, Any]]:
        """This wallet's recorded XvB raffle wins at or after ``since`` (default: all),
        oldest first — bounded to the newest ``RAFFLE_WINS_MAX_ROWS`` so the per-poll
        ``/api/state`` read can never become an unbounded scan (security review)."""
        try:
            with self._db_lock:
                if not self._conn:
                    return []
                cursor = self._conn.cursor()
                cursor.execute(
                    "SELECT ts, hashrate, height, block_id, tier FROM "
                    "(SELECT ts, hashrate, height, block_id, tier FROM raffle_wins "
                    "WHERE ts >= ? ORDER BY ts DESC LIMIT ?) ORDER BY ts ASC",
                    (since, _raffle_wins_max_rows()),
                )
                return [dict(row) for row in cursor.fetchall()]
        except sqlite3.Error as e:
            self.logger.error(f"Raffle Win Read Error: {e}")
            return []

    def add_worker_history(self, rows: list[dict[str, Any]]) -> None:
        """Record one poll's per-worker hashrate/share-count samples (#196) in a SINGLE
        executemany call — the caller batches every online worker for one wall-clock tick rather
        than issuing N inserts per cycle. 30-day retention. Each row needs ts/name/h15/accepted/
        rejected; a missing key defaults to 0/''. A no-op on an empty batch."""
        if not rows:
            return
        prune_ts = rows[0].get("ts", time.time())
        try:
            values = [
                (
                    r.get("ts", prune_ts),
                    r.get("name", ""),
                    r.get("h15", 0) or 0,
                    r.get("accepted", 0) or 0,
                    r.get("rejected", 0) or 0,
                )
                for r in rows
            ]
            with self._db_lock:
                if not self._conn:
                    return
                with self._conn:
                    self._conn.executemany(
                        "INSERT INTO worker_history (ts, name, h15, accepted, rejected) "
                        "VALUES (?, ?, ?, ?, ?)",
                        values,
                    )
                    if random.random() < 0.05:  # noqa: S311 — pruning sampler, not a security context
                        self._conn.execute(
                            "DELETE FROM worker_history WHERE ts < ?",
                            (prune_ts - WORKER_HISTORY_RETENTION_SEC,),
                        )
            self._table_write_ok("worker_history", prune_ts)
        except sqlite3.Error as e:
            self._table_write_failed("worker_history", "Worker History Insert Error", e)

    def get_worker_history(
        self, since: float = 0.0, name: str | None = None
    ) -> list[dict[str, Any]]:
        """Per-worker hashrate/share samples at or after `since` (default: all), oldest first.
        `name` restricts to one rig's series (#492); omit it for every rig's samples."""
        try:
            with self._db_lock:
                if not self._conn:
                    return []
                cursor = self._conn.cursor()
                if name is not None:
                    cursor.execute(
                        "SELECT ts, name, h15, accepted, rejected FROM worker_history "
                        "WHERE ts >= ? AND name = ? ORDER BY ts ASC",
                        (since, name),
                    )
                else:
                    cursor.execute(
                        "SELECT ts, name, h15, accepted, rejected FROM worker_history "
                        "WHERE ts >= ? ORDER BY ts ASC",
                        (since,),
                    )
                return [dict(row) for row in cursor.fetchall()]
        except sqlite3.Error as e:
            self.logger.error(f"Worker History Read Error: {e}")
            return []

    def get_worker_hashrate_by_config(
        self, worker: str, since: float = 0.0
    ) -> list[dict[str, Any]]:
        """Correlate `worker`'s measured hashrate (worker_history) to the config version active at
        each sample's timestamp (#492 — rides #185's worker_config + #196's worker_history). Each
        *applied* worker_config row is a version boundary; a sample belongs to the most recent
        applied change at or before its ts, so an operator can compare "config #3 did X, config #4
        did Y" empirically. Bucketing is in Python (bisect) — the version count is small (`limit`
        below) and this reads far more clearly than a correlated-subquery/window-function SQL
        version. Returns one row per version, newest first, matching get_worker_config_history:
        `{change_id, ts, reason, sample_count, avg_h15, min_h15, max_h15}` (the h15 fields are
        `None` for a version with zero samples). Samples that predate the first applied change have
        no known version and are dropped — out of scope: correlate to a KNOWN version, don't guess
        at pre-history config."""
        versions = [
            row
            for row in reversed(self.get_worker_config_history(worker, limit=200) or [])
            if row.get("status") == "applied"
        ]
        if not versions:
            return []
        boundaries = [v["ts"] for v in versions]  # oldest first, aligned with `versions`
        buckets: list[list[float]] = [[] for _ in versions]
        for s in self.get_worker_history(since=since, name=worker):
            idx = bisect.bisect_right(boundaries, s["ts"]) - 1
            if idx >= 0:
                buckets[idx].append(s["h15"])

        out = [
            {
                "change_id": v["change_id"],
                "ts": v["ts"],
                "reason": v.get("reason"),
                "sample_count": len(vals),
                "avg_h15": sum(vals) / len(vals) if vals else None,
                "min_h15": min(vals) if vals else None,
                "max_h15": max(vals) if vals else None,
            }
            for v, vals in zip(versions, buckets, strict=True)
        ]
        out.reverse()  # newest first
        return out
