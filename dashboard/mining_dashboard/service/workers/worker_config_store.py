"""The dashboard's own record of the worker config changes it sent (#185), split out of
`storage_service.py`.

This is a MIXIN, not a facade: `StateManager` inherits it, so these methods keep the same `self`,
the same `_conn`, the same `_db_lock` and the same transaction scope they had when they were
defined inline. That distinction is what the #1105 "do not split `storage_service.py`" ruling
turns on — it refused a new seam between callers and the single DB handle, and a mixin introduces
none. The same narrowing the telemetry split was taken under (#1369), and the same proof class,
except that the proof now ships as `tests/service/test_mixin_atomicity.py` rather than as a
one-off pass: no method here holds a transaction or cursor across a call into a method that
stayed behind, and CI re-checks that on every later PR instead of once.

The boundary is the `worker_config` TABLE — every accessor of it moves and nothing else does, so
the seam is one the code already drew rather than one invented for the cut. `worker_history` and
its `get_worker_hashrate_by_config` reader stay behind: that pair is hashrate telemetry keyed by
config version, not the change record itself.

Why this cut was taken: `storage_service.py` sat at its recorded file-budget ceiling with zero
headroom, and #1369's fix — an exact-id provenance lookup the 50-row history window cannot answer
— has to land somewhere. It lands here, in the module that owns the table it reads.
"""

import json
import random
import sqlite3
import time
from typing import Any

# The credential strip the rig-read path already uses (``client/xmrig_client._rig_writable_config``),
# reused rather than restated — a second key list is a second place for it to drift, and this table
# feeds the SAME editor prefill that one defends (#1543).
from mining_dashboard.client.xmrig_client import strip_credentials
from mining_dashboard.config.config import HISTORY_RETENTION_SEC

_RECONCILE_TERMINAL = ("applied", "rejected", "rolled_back", "failed", "noop", "throttled", "busy")

# One column list for every read of this table that returns a ROW, so a windowed read and an
# exact-id read cannot drift into returning differently-shaped rows for the same change
# (#1369). `worker_config_change_known` deliberately does not use it — see its docstring.
_SELECT_CHANGE = "SELECT change_id, ts, status, changes, reason, type FROM worker_config"


# A rig names its own ``change_id``, ``reason`` and worker ``name`` on the unauthenticated enriched
# feed, and ``json.loads`` hands a lone surrogate (U+D800) straight back as a ``str``. sqlite3
# encodes a TEXT parameter as strict UTF-8 and raises ``UnicodeEncodeError`` on one — a
# ``ValueError``, NOT a ``sqlite3.Error``, so it walks through every fail-closed handler in this
# file and out through the caller's ``asyncio.to_thread``, aborting the poll step rather than being
# handled (#1696). Refusing the bind up front lets each method answer its OWN contract, which is
# the part a uniform fix gets wrong: widening every ``except`` to the same tuple would route this
# input into ``worker_config_change_known``'s deliberate fail-OPEN and hand a rogue rig a way to
# opt out of being audited by putting one character in its ``change_id``.
#
# The encode is sqlite's own operation rather than a charset test that could disagree with it. The
# verdict accumulates instead of returning from inside the handler, which keeps this predicate's
# ``False`` an ANSWER about the input rather than an error path hidden in a success type.
def _bindable(*values: object) -> bool:
    """Whether sqlite3 can bind every string in ``values`` as a TEXT parameter (#1696)."""
    ok = True
    for value in values:
        if isinstance(value, str):
            try:
                value.encode("utf-8")
            except UnicodeEncodeError:
                ok = False
    return ok


def _shaped(row: sqlite3.Row) -> dict:
    """One ``worker_config`` row as the rest of the app reads it: ``changes`` parsed back to a
    dict (unparseable JSON reads as ``{}`` rather than raising), credentials stripped out of it,
    and a row written before the ``type`` column existed (#1014) reading back as ``"apply"``.

    The strip is HERE, and not at any of the three places that publish ``changes``, because this
    is the one point both row-returning reads pass through — ``get_worker_config_history`` and
    ``get_worker_config_change`` — and therefore the only single edit that covers every consumer
    of them (#1543). The Inspect payload alone carries a row's ``changes`` in three separate
    fields: ``last_applied`` (merged here), ``history``, and ``hashrate_history.markers[]``.
    Stripping at ``get_last_applied_worker_config``, which is where the issue's own text points,
    would have left the other two serving the credential, and nothing would have gone red.

    It is also what makes an ALREADY-WRITTEN row safe: ``add_worker_config_version`` stops new
    rows carrying a credential, but rows a previous build wrote still hold one, and this is what
    keeps those from being served without needing a migration to rewrite them."""
    d = dict(row)
    try:
        d["changes"] = json.loads(d["changes"]) if d["changes"] else {}
    except (TypeError, ValueError):
        d["changes"] = {}
    d["changes"] = strip_credentials(d["changes"])
    d["type"] = d.get("type") or "apply"
    return d


def _next_drift_from(
    row: sqlite3.Row | None, revision: str, last_change_id: str | None
) -> str | None:
    """The ``drift_from`` to store on this poll (#1564), given the row read on the same poll.

    Split out of ``note_worker_revision`` because it IS the currency rule and is worth settling
    without a database: the Inspect note must survive the polls AFTER the one that raised it — a
    drift the operator has not resolved is still true — and go quiet once the config is
    accounted for again. ``None`` means say nothing, for two reasons: a first sighting has
    nothing to compare, and a revision that moved WITH a new ``last_change_id`` is the RESOLVED
    case — something recorded that change, so the line has nothing left to contradict.
    """
    if row is None:
        return None
    if row["revision"] == revision:
        # The rig has not moved, so a drift already recorded against this revision is still the
        # current one. INSERT OR REPLACE rewrites every column, so carrying it is not a no-op.
        return row["drift_from"]
    return row["revision"] if row["last_change_id"] == last_change_id else None


class WorkerConfigStoreMixin:
    """The `worker_config` accessors of `StateManager`. Never instantiated on its own."""

    def add_worker_config_version(
        self,
        worker: str,
        change_id: str | None,
        status: str,
        changes: dict[str, Any],
        reason: str | None,
        ts: float | None = None,
        change_type: str = "apply",
    ) -> None:
        """Record one applied/attempted worker change (#185): a config apply, or (``change_type=
        "upgrade"``, #1014) a one-click RigForge upgrade attempt — ``changes`` then carries
        ``{"version": ...}`` instead of a writable-key diff. Forward-only.

        Stored as JSON with the pool credentials stripped OUT of it first (#1543). That sentence
        used to read "no secret ever lands here", which was not a property this method had: the
        caller hands us the operator's own POSTed ``changes``, ``pools`` is on the writable
        allowlist, and a pool entry carries ``pass``, so the credential landed here in plain text
        and stayed — through a restart, and into any backup of the DB.

        The strip is on the RECORD only. ``handle_worker_apply`` sends the operator's unmodified
        ``changes`` to the rig before calling this, so the password still reaches the pool it is
        for; what changes is what this dashboard keeps afterwards. ``strip_credentials`` builds
        new containers rather than mutating, so the caller's dict is untouched either way.

        One disclosed consequence: the strip stops walking past ``_MAX_CONFIG_DEPTH`` (6) and
        returns ``None`` below it, so a ``changes`` nested deeper than that is recorded truncated.
        A writable config is three deep at most (``pools`` -> a pool -> its fields), so nothing a
        rig accepts reaches the bound — but the audit row, not the rig, is what would lose."""
        try:
            with self._db_lock:
                if not self._conn:
                    return
                self._conn.execute(
                    "INSERT INTO worker_config (worker, change_id, ts, status, changes, reason, type) "
                    "VALUES (?, ?, ?, ?, ?, ?, ?)",
                    (
                        worker,
                        change_id,
                        ts if ts is not None else time.time(),
                        status,
                        json.dumps(strip_credentials(changes)),
                        reason,
                        change_type,
                    ),
                )
                self._conn.commit()
        except (sqlite3.Error, TypeError, ValueError) as e:
            self._db_error("Worker Config Write Error", e)

    def get_worker_config_history(self, worker: str, limit: int = 50) -> list[dict] | None:
        """The change history for ``worker``, newest first, ``changes`` parsed back to a dict.
        ``type`` is ``"apply"``/``"upgrade"`` (#1014); a pre-column row reads back ``"apply"``.
        None means the read FAILED (no connection, or ``sqlite3.Error``); ``[]`` = no history."""
        try:
            with self._db_lock:
                if not self._conn:
                    return None
                cursor = self._conn.cursor()
                cursor.execute(
                    f"{_SELECT_CHANGE} WHERE worker = ? ORDER BY ts DESC, id DESC LIMIT ?",
                    (worker, limit),
                )
                return [_shaped(row) for row in cursor.fetchall()]
        except sqlite3.Error as e:
            self.logger.error(f"Worker Config Read Error: {e}")
            return None

    def reconcile_worker_config_status(
        self, change_id: str, status: str, reason: str | None = None
    ) -> None:
        """Catch up a still-``accepted`` #185 history row to its now-known terminal outcome (#579).

        A rig rollback slower than the host runner's status-poll deadline (#517/#543) leaves its
        row ``accepted`` forever otherwise — nothing re-polls it. This is the reconciler: called
        from the dashboard's regular per-rig read poll (data_service.py), never a new dial. The
        ``WHERE status = 'accepted'`` is the whole safety property — a row already terminal
        (applied/rejected/rolled_back/failed/noop/throttled) is never touched, even by a stale or
        duplicate report for the same ``change_id``. ``status`` is recorded as-is: it becomes the
        row's outcome verbatim, and the frontend's ``STATUS_META`` already renders every member of
        this vocabulary (``workerview.mjs``).

        Both rig-chosen fields go through ``_bindable`` (#1696), in the two directions their own
        roles ask for. A ``change_id`` sqlite cannot bind could match no row anyway — nothing
        non-encodable was ever written — so it returns. A ``reason`` it cannot bind is recorded as
        ``None`` instead of refusing the call: ``reason`` is display prose beside the outcome, and
        the terminal ``status`` is the thing this exists to catch up. Refusing on the prose would
        strand the row on ``accepted`` for as long as the rig kept resending it, which is the very
        state #579 was written to clear.
        """
        if status not in _RECONCILE_TERMINAL or not change_id or not _bindable(change_id):
            return
        if not _bindable(reason):
            reason = None
        try:
            with self._db_lock:
                if not self._conn:
                    return
                self._conn.execute(
                    "UPDATE worker_config SET status = ?, reason = ? "
                    "WHERE change_id = ? AND status = 'accepted'",
                    (status, reason, change_id),
                )
                self._conn.commit()
        except sqlite3.Error as e:
            self._db_error("Worker Config Reconcile Error", e)

    def get_worker_config_change(self, worker: str, change_id: str) -> dict | None:
        """This rig's own row for ``change_id``, looked up by id rather than searched for in a
        window (#1369).

        The provenance verdict needs to know whether a change id the rig names is one we spooled
        for THIS rig, and what became of it. Scanning the bounded history the page renders could
        only answer that for a rig whose change was still inside the window; past it the feature
        stopped working in both directions at once — it could neither claim a change that was ours
        nor name one that was not. A lookup by id has no such horizon: `EXPLAIN QUERY PLAN`
        reports `SEARCH worker_config USING INDEX idx_worker_config (worker=?)`, so it seeks
        this rig's rows and walks only those, in the order that index already supplies.

        Three-valued on the #1409 contract, and it fails CLOSED: ``None`` means the read FAILED
        (no connection, or ``sqlite3.Error``), ``{}`` means there is genuinely no such row for
        this worker, and a dict is the row. Worker-scoped on purpose — ``worker_config_change_known``
        below asks the deliberately unscoped question for #530, and answering this one with it
        would let a change spooled for a DIFFERENT rig read as this rig's own.

        Ordering matches ``get_worker_config_history``, so this returns the same row the window
        scan it replaces would have matched.
        """
        if not change_id:
            return {}
        try:
            with self._db_lock:
                if not self._conn:
                    return None
                cursor = self._conn.cursor()
                cursor.execute(
                    f"{_SELECT_CHANGE} WHERE worker = ? AND change_id = ? "
                    "ORDER BY ts DESC, id DESC LIMIT 1",
                    (worker, change_id),
                )
                row = cursor.fetchone()
                return _shaped(row) if row is not None else {}
        except sqlite3.Error as e:
            self.logger.error(f"Worker Config Change Read Error: {e}")
            return None

    def worker_config_change_known(self, change_id: str) -> bool:
        """Whether ``change_id`` was ever spooled by THIS dashboard (#530): a row exists in
        ``worker_config`` — the table only ``add_worker_config_version`` writes to, one row per
        change the dashboard itself sent. A rig reporting a terminal outcome for a change_id NOT
        found here is reporting something it applied on its own — an out-of-band rig edit.

        Unscoped, and it fails OPEN, both deliberately and both the opposite of
        ``get_worker_config_change`` above — this method must return ``False`` on a closed handle
        and ``True`` on a ``sqlite3.Error``, where the provenance path needs the same answer for
        both, so no one three-valued helper can serve them.

        It keeps its own query too, and that is the point rather than an oversight: this asks only
        whether a row EXISTS. It never reads ``ts``, so it needs no ``ORDER BY``, and it never
        reads the row, so it needs neither the column list nor ``_shaped``. Answering it through
        the provenance query cost a temp B-tree sort per call for nothing — measured with
        `EXPLAIN QUERY PLAN`, and `_reconcile_worker_config` calls this once per reporting rig per
        poll. What the two genuinely must share is the ROW SHAPE, and only the reads that return a
        row have that in common; ``_SELECT_CHANGE`` is where they share it.

        A ``change_id`` sqlite cannot bind answers ``False``, and that is the CORRECT answer rather
        than this method's fail-open direction applied to a new input (#1696).
        ``add_worker_config_version`` is the only writer to this table and its own bind of the same
        value would have raised, so a non-encodable id has never been a row here and "never spooled
        by this dashboard" is the true answer. The rig is then flagged for an out-of-band edit, which is
        what a terminal report for a change this dashboard never sent IS.
        """
        if not change_id or not _bindable(change_id):
            return False
        try:
            with self._db_lock:
                if not self._conn:
                    return False
                cursor = self._conn.cursor()
                cursor.execute(
                    "SELECT 1 FROM worker_config WHERE change_id = ? LIMIT 1", (change_id,)
                )
                return cursor.fetchone() is not None
        except sqlite3.Error as e:
            self.logger.error(f"Worker Config Lookup Error: {e}")
            return True  # fail toward NOT flagging a false rig-edit on a DB read hiccup

    def note_worker_revision(
        self, worker: str, meta: dict | None, rigforge_version: str | None = None
    ) -> dict | None:
        revision = (meta or {}).get("revision")
        if not worker or not revision or not _bindable(worker):
            return None
        last_change_id = meta.get("last_change_id")
        try:
            with self._db_lock:
                if not self._conn:
                    return None
                cursor = self._conn.cursor()
                cursor.execute(
                    "SELECT revision, last_change_id, drift_from, rigforge_version "
                    "FROM worker_config_revision WHERE worker = ?",
                    (worker,),
                )
                row = cursor.fetchone()
                rebased = (
                    row is not None
                    and row["revision"] != revision
                    and rigforge_version is not None
                    and row["rigforge_version"] != rigforge_version
                )
                if row is not None and rigforge_version is None:
                    rigforge_version = row["rigforge_version"]
                drift_from = _next_drift_from(None if rebased else row, revision, last_change_id)
                now = time.time()
                self._conn.execute(
                    "INSERT OR REPLACE INTO worker_config_revision "
                    "(worker, revision, last_change_id, ts, drift_from, rigforge_version) "
                    "VALUES (?, ?, ?, ?, ?, ?)",
                    (worker, revision, last_change_id, now, drift_from, rigforge_version),
                )
                if random.random() < 0.05:  # noqa: S311 — pruning sampler, not a security context
                    self._conn.execute(
                        "DELETE FROM worker_config_revision WHERE ts < ?",
                        (now - HISTORY_RETENTION_SEC,),
                    )
                self._conn.commit()
        except sqlite3.Error as e:
            self._db_error("Worker Revision Write Error", e)
            return None
        if row is None or rebased or row["revision"] == revision:
            return None
        if row["last_change_id"] != last_change_id:
            return None
        return {"worker": worker, "before": row["revision"], "after": revision}

    def _migrate_worker_config_revision(self, cursor: sqlite3.Cursor) -> None:
        cursor.execute("PRAGMA table_info(worker_config_revision)")
        columns = {info[1] for info in cursor.fetchall()}
        for column in ("drift_from", "rigforge_version"):
            if column not in columns:
                self.logger.info(f"Migrating DB: Adding {column} column to worker_config_revision")
                self._conn.execute(f"ALTER TABLE worker_config_revision ADD COLUMN {column} TEXT")

    def get_worker_revision_drift(self, worker: str, revision: str | None) -> dict | None:
        """The unrecorded config edit the Inspect provenance line should still be reporting for
        ``worker`` (#1564), as ``{worker, before, after}`` — or ``None``, meaning say nothing.

        Gated on CURRENCY, never on existence. The ``rig-drift`` audit row is permanent and that
        durable record is the Security panel's job; this line describes the config the rig is
        serving NOW, so it answers only while the drift we stored produced ``revision`` — what
        the rig reports on THIS poll. "Ever drifted?" would accuse a rig forever, long after the
        operator adopted the change.

        Two states by construction, never three: no "checked and agrees" verdict, for the reason
        ``config_drift`` withholds its ``[]`` — an all-clear here would be a reassurance bounded
        by narrowings the operator cannot see from a badge, this feature's own defect inverted.

        Deliberately NOT a lookup of the ``rig-drift`` audit row by its ``event_id``: that id is
        deterministic and the join is cheaper, but its format is not a contract, and a lookup
        built on one would fail SILENTLY when the format moved — the note would stop rendering
        and every test written against the old shape would stay green.

        Fails CLOSED: a read error or a closed handle returns ``None`` and the line says nothing.
        """
        if not worker or not revision:
            return None
        try:
            with self._db_lock:
                if not self._conn:
                    return None
                cursor = self._conn.cursor()
                cursor.execute(
                    "SELECT revision, drift_from FROM worker_config_revision WHERE worker = ?",
                    (worker,),
                )
                row = cursor.fetchone()
        except sqlite3.Error as e:
            self._db_error("Worker Revision Read Error", e)
            return None
        if row is None or not row["drift_from"] or row["revision"] != revision:
            return None
        return {"worker": worker, "before": row["drift_from"], "after": revision}

    def get_last_applied_worker_config(self, worker: str) -> dict[str, Any]:
        """The merged writable config the dashboard last successfully applied to ``worker`` — the
        best prefill for the editor, since the rig's enriched feed does not expose the writable config
        values (#185). Later applied changes lay over earlier ones (last write wins per key).
        Upgrade rows (#1014) are excluded — their ``changes`` is a ``{"version": ...}`` marker, not
        writable-key config, and must never leak into the editor prefill."""
        merged: dict[str, Any] = {}
        for row in reversed(self.get_worker_config_history(worker, limit=200) or []):
            if (
                row.get("status") == "applied"
                and row.get("type", "apply") == "apply"
                and isinstance(row.get("changes"), dict)
            ):
                merged.update(row["changes"])
        return merged
