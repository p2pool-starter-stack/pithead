import asyncio
import logging
import time
import uuid

from mining_dashboard.client.xmrig_client import (
    parse_worker_control_status,
)
from mining_dashboard.config import config
from mining_dashboard.service import audit_service
from mining_dashboard.service.control_service import (
    env_key_config_paths,
)
from mining_dashboard.service.data_helpers import (
    _diff_config_keys,
    _iso_now,
    _parse_audit_ts,
    _read_host_config,
)
from mining_dashboard.service.workers import worker_change_audit

logger = logging.getLogger("DataService")


# Per-worker flood cap on NEW out-of-band audit rows (#724). The enriched worker feed is
# unauthenticated LAN input, so a rogue device presenting as a worker can report a fresh random
# change_id every poll — each a distinct, permanent audit_events row (#530's deterministic id only
# collapses REPEATS of one change_id, never distinct ones). At most _RIG_EDIT_CAP_PER_HOUR genuine
# rows per worker per rolling hour; beyond that, rows are dropped and a single rate-limited marker
# is recorded + logged. A real fleet edits a rig a handful of times an hour at most, so a
# legitimate cadence never trips it — only a flood does.
# ONE budget covers BOTH detections on this feed: rig-edit (#530) and revision-drift (#1551).
# revision has the identical property — the store's dedup collapses an UNCHANGED revision and does
# nothing about one that changes every poll — so a second window would just double what one
# untrusted source can make permanent. See service/workers/worker_change_audit.py.
_RIG_EDIT_CAP_PER_HOUR = 12
_RIG_EDIT_WINDOW_SEC = 3600


class DataAuditMixin:
    async def _record_audit_event(self, source, actor, action, status, keys, event_id=None):
        """Write one out-of-band audit row (#530), through the SAME sanitizer #33's own audit
        trail is served through (``audit_service._clean``) — defense in depth: ``actor``/``keys``
        here are already schema-shaped (a validated worker name, dotted config-key paths), but
        every field the Security panel serves gets the identical whitelist treatment regardless of
        source — the row ``id`` included, since #1561.

        ``event_id`` lets a caller supply a DETERMINISTIC row id so ``INSERT OR IGNORE`` collapses
        repeat reports of the SAME event to one row (rig-edit: a rig re-reports its last change_id
        every poll); ``clean_event_id`` bounds it HERE, at the sink, not at each caller. A host-edit
        passes None — a distinct event each time, so the random id is right there."""
        await asyncio.to_thread(
            self.state_manager.add_audit_event,
            id=audit_service.clean_event_id(event_id) or f"{source}-{uuid.uuid4()}",
            ts=_iso_now(),
            source=audit_service._clean(source, 16),
            actor=audit_service._clean(actor, 64),
            action=audit_service._clean(action, 16),
            status=audit_service._clean(status, 32),
            keys=audit_service._clean(keys, 400),
        )

    async def _watch_host_config(self):
        """Out-of-band HOST-EDIT detection (#530): config.json changed without a matching
        control-channel commit.

        Reads the same pre-masked copy the control channel itself prefills from
        (``config.HOST_CONFIG_PATH``, #440 — already secret-free) each poll and diffs it against
        the previous poll's snapshot. A changed key is "explained" — and stays quiet — only when
        the #33 audit trail shows a ``commit``/``applied`` entry that both landed AFTER the last
        time this watcher looked AND actually touched that key (the entry's env-var names are
        bridged to config paths via ``env_key_config_paths``). Correlating by key, not merely by
        time, is what stops a legit dashboard commit of key A from swallowing a concurrent
        host-side hand-edit of key B. Any changed key no fresh commit covers (a hand-edit, a
        `pithead apply` run outside the dashboard) is recorded as a ``host-edit`` audit row naming
        the unexplained keys. First poll only baselines (no control
        log exists yet to compare against, and every other watcher in this loop shares that
        never-backfill contract). No-op with the control channel off — there is neither a masked
        config mount nor an audit trail to compare against."""
        if not config.DASHBOARD_CONTROL_ENABLED:
            return
        current = await asyncio.to_thread(_read_host_config)
        if current is None:
            return  # mount not ready yet — quiet no-op, the next poll retries
        now = time.time()
        if self._last_host_config is None:
            self._last_host_config, self._last_host_check = current, now
            return
        changed_keys = _diff_config_keys(self._last_host_config, current)
        if changed_keys:
            # The audit log's ts is whole-second (_iso_now/control_audit both write
            # "%Y-%m-%dT%H:%M:%SZ"), while `_last_host_check` is a sub-second time.time() — a
            # commit landed in the SAME wall-clock second as the baseline poll would otherwise
            # floor below it and be missed. One second of grace absorbs that truncation.
            # ponytail: ≤1s correlation window — a control-channel commit up to 1s before the last
            # poll could "explain" (suppress) an unrelated hand-edit detected in this poll. The
            # honest ceiling of a timestamp correlation; tighten to id-based ("commits seen since
            # last poll") only if a real false-negative shows up. Pinned by
            # test_explained_window_is_at_most_one_second.
            since = self._last_host_check - 1
            # Correlate BY KEY, not just by time: a commit only "explains" the keys it actually
            # touched. Fold every fresh commit's env-var names into the config paths they cover
            # (env_key_config_paths bridges the audit log's env names to config.json paths), then
            # record only the changed keys NO recent commit covers — the genuine out-of-band edits
            # this watcher exists to catch. A concurrent dashboard commit of key A + a host
            # hand-edit of key B no longer swallows B.
            explained_paths = set()
            for e in audit_service.recent_changes():
                if (
                    e.get("action") in ("commit", "commit-confirmed", "commit-approved")
                    and e.get("status") == "applied"
                    and (ts := _parse_audit_ts(e.get("ts"))) is not None
                    and ts >= since
                ):
                    for env_key in (e.get("keys") or "").split():
                        explained_paths.update(env_key_config_paths(env_key))
            # ponytail: env-var granularity — a var fed by >1 config path (e.g. P2POOL_FLAGS <-
            # p2pool.pool + p2pool.clearnet) explains ALL its paths, so a commit touching one could
            # still suppress a concurrent hand-edit of its sibling. Inherent to a name-only audit
            # log; fix only if per-path audit keys ever land.
            unexplained = [
                k
                for k in changed_keys
                if not any(k == p or k.startswith(p + ".") for p in explained_paths)
            ]
            if unexplained:
                await self._record_audit_event(
                    "host-edit", "", "host-edit", "detected", " ".join(unexplained)
                )
        self._last_host_config, self._last_host_check = current, now

    async def _mirror_control_audit(self):
        """Copy the #33 control.log's recent entries into the durable ``audit_events`` table
        (#530), so the Security panel's time-grouped view can drill deeper than the log's own
        trimmed tail. ``audit_service.recent_changes()`` output is already sanitized (it's the SAME
        read the panel used before this table existed); ``add_audit_event``'s ``INSERT OR IGNORE``
        on the log's own ``id`` makes re-mirroring the same tail every poll a no-op. Entries with no
        id (a handful of pre-auth "invalid"/"refused" rows, #33) are skipped — they're visible only
        while still in the log tail, same as before this feature."""
        if not config.DASHBOARD_CONTROL_ENABLED:
            return
        # The log reader returns newest first, but preview and terminal commit share an id. Replay
        # oldest first so the terminal outcome is the row left in durable history, not the preview
        # that happened to be mirrored first.
        for e in reversed(audit_service.recent_changes()):
            if not e.get("id"):
                continue
            await asyncio.to_thread(
                self.state_manager.add_audit_event,
                id=e["id"],
                ts=e.get("ts", ""),
                source="control",
                actor=e.get("actor", ""),
                action=e.get("action", ""),
                status=e.get("status", ""),
                keys=e.get("keys", ""),
            )

    def _rig_edit_within_cap(self, worker, now):
        """Per-worker fixed-window cap on NEW rig-edit audit rows (#724). Counts this rig-edit
        against the worker's current hour window and returns ``(allowed, first_over)``: ``allowed``
        is True while the worker is under ``_RIG_EDIT_CAP_PER_HOUR`` this window; ``first_over`` is
        True only on the single call that tips it over, so the caller logs + records the
        rate-limited marker exactly once per window rather than every poll. A handful of real edits
        an hour never trips it; a rig spamming distinct change_ids does.

        A name this map has never admitted goes through ``worker_change_audit.admit_worker`` first
        (#1695), which bounds the device-chosen name space; a refusal returns here with the same
        ``(allowed, first_over)`` shape, so both callers stay unchanged and the marker for it is
        written by the same ``record_cap_marker`` the per-worker case uses."""
        admitted, first_names_over = worker_change_audit.admit_worker(
            self, worker, now, _RIG_EDIT_WINDOW_SEC
        )
        if not admitted:
            return False, first_names_over
        start, count = self._rig_edit_window.get(worker, (now, 0))
        if now - start >= _RIG_EDIT_WINDOW_SEC:
            start, count = now, 0
        # Load-bearing OUTSIDE this module: worker_change_audit.record_cap_marker reads a
        # worker's ABSENCE from this map as the #1695 names-ceiling refusal, so this
        # unconditional write is what makes a #724 per-worker trip present. Make it conditional
        # and every per-worker trip silently writes the names-ceiling marker instead.
        self._rig_edit_window[worker] = (start, count + 1)
        return count < _RIG_EDIT_CAP_PER_HOUR, count == _RIG_EDIT_CAP_PER_HOUR

    async def _reconcile_worker_config(self, workers, worker_results):
        """Catch up any still-``accepted`` #185 worker-config history row whose change_id the rig
        now reports terminal (#579), and flag an out-of-band RIG-EDIT (#530).

        A rollback slower than the host runner's 20s status-poll deadline (#517/#543) is honestly
        recorded ``accepted`` and never revisited — this rides THIS poll's already-fetched enriched
        bodies (``worker_results``, positionally aligned with ``workers`` and with the worker probes
        in ``run()``), so there's no new dial and no host-runner change. A plain-xmrig rig, a rig
        still mid-change, or an unreachable/offline rig (``{}``) all parse to ``None`` via
        ``parse_worker_control_status`` and are a quiet no-op.

        A TERMINAL report whose ``change_id`` this dashboard never spooled (``worker_config`` has no
        row for it — checked via ``worker_config_change_known``) is a change the RIG applied on its
        own: reconciling it would be a silent no-op anyway (the ``WHERE status='accepted'`` UPDATE
        matches nothing), so instead it's recorded as a ``rig-edit`` audit row naming the worker.
        RigForge's ``/status`` mirror carries only the outcome of a change, not a per-key diff, so
        unlike host-edit's ``keys`` this can only name the change_id — a real limitation, not an
        oversight; see the #530 PR notes.

        Each worker's revision is also checked for drift here (#1551), before the control-status
        guard below, because a rig can serve a moved ``revision`` with no terminal outcome beside
        it and that is the case nothing else can see; it shares this method's flood cap.

        A rig keeps reporting its last terminal change_id every poll, so this fires ONCE per
        (worker, change_id): an in-memory guard skips the redundant work in the steady state, and
        the audit row's deterministic id makes the write itself idempotent even across a restart
        (when the guard is empty but a repeat report must still not duplicate the row). Both matter
        — the id is the correctness bound (a rogue rig can't flood the permanent table with repeats
        of one bogus change_id), the guard is the optimisation.

        DISTINCT change_ids each clear that dedup, though, so a rogue rig on the unauthenticated
        feed can still write one permanent row per poll (#724). ``_rig_edit_within_cap`` bounds NEW
        out-of-band rows to ``_RIG_EDIT_CAP_PER_HOUR`` per worker per hour — rig-edit and
        revision-drift share the one budget; beyond that the row is dropped, but never silently: a
        single ``rate-limited`` marker naming which detection tipped it is logged and recorded so
        the flood stays visible in the Security panel. host-edit rows are unaffected (a different,
        non-attacker-controlled path)."""
        for w, extra_stats in zip(workers, worker_results, strict=False):
            await worker_change_audit.note_revision_drift(
                self, w, extra_stats, _RIG_EDIT_CAP_PER_HOUR
            )
            ctrl = parse_worker_control_status(extra_stats) if extra_stats else None
            if not ctrl:
                continue
            known = await asyncio.to_thread(
                self.state_manager.worker_config_change_known, ctrl["change_id"]
            )
            if known:
                await asyncio.to_thread(
                    self.state_manager.reconcile_worker_config_status,
                    ctrl["change_id"],
                    ctrl["status"],
                    ctrl["reason"],
                )
            else:
                worker = w.get("name", "")
                guard_key = (worker, ctrl["change_id"])
                if guard_key in self._flagged_rig_changes:
                    continue
                allowed, first_over = self._rig_edit_within_cap(worker, time.time())
                if not allowed:
                    # Over cap this window — drop the row, and don't add to the guard set, so its
                    # size stays bounded by what we actually record rather than by the flood. The
                    # marker itself is shared with revision-drift (#1551): one budget, one marker.
                    if first_over:
                        await worker_change_audit.record_cap_marker(
                            self, worker, _RIG_EDIT_CAP_PER_HOUR, "rig-edit"
                        )
                    continue
                self._flagged_rig_changes.add(guard_key)
                await self._record_audit_event(
                    "rig-edit",
                    worker,
                    "rig-edit",
                    ctrl["status"],
                    f"change_id={ctrl['change_id']}",
                    event_id=audit_service.build_event_id("rig-edit", worker, ctrl["change_id"]),
                )

    def _on_clearnet_transition(self, name, ok):
        """Called by the supervisor after a clearnet→Tor flip attempt (#234)."""
        if ok:
            logger.info("%s returned to Tor after its clearnet initial sync (#234).", name)
        else:
            logger.warning(
                "%s clearnet→Tor switch did not complete this cycle — will retry (#234).", name
            )
