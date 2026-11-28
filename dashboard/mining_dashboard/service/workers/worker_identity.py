import time

from mining_dashboard.config import config

IDENTITY_WINDOW_POLLS = 3
IDENTITY_WINDOW_S = IDENTITY_WINDOW_POLLS * config.UPDATE_INTERVAL
_MAX_TRACKED_RIGS = 1024
_MAX_SOURCES_PER_RIG = 8
MOVED_EVENT_INTERVAL_S = 3600

_faulted_names = frozenset()


def stamp(request):
    if request.get("worker") in _faulted_names:
        request["duplicate_identity"] = True
    return request


class RigIdentityTracker:
    def __init__(self, window_s=IDENTITY_WINDOW_S):
        self._window_s = window_s
        self._rigs = {}

    def _live(self, rec, now):
        return {s: v for s, v in rec["sources"].items() if now - v[0] <= self._window_s}

    def sweep(self, now):
        for rig_id in list(self._rigs):
            rec = self._rigs[rig_id]
            rec["sources"] = self._live(rec, now)
            if not rec["sources"]:
                del self._rigs[rig_id]

    def observe(self, rig_id, source, fingerprint, credential, now):
        rec = self._rigs.get(rig_id)
        if rec is None:
            if len(self._rigs) >= _MAX_TRACKED_RIGS:
                return False
            rec = self._rigs[rig_id] = {"credential": credential, "sources": {}}
        if rec["credential"] != credential:
            rec["credential"], rec["sources"] = credential, {}
        rec["sources"] = self._live(rec, now)
        prev = rec["sources"].get(source)
        if prev is None and len(rec["sources"]) >= _MAX_SOURCES_PER_RIG:
            return False
        moved = bool(prev and prev[1] and fingerprint and prev[1] != fingerprint)
        moved = moved and now - rec.get("moved_at", float("-inf")) >= MOVED_EVENT_INTERVAL_S
        if moved:
            rec["moved_at"] = now
        rec["sources"][source] = (now, fingerprint or (prev[1] if prev else None))
        return moved

    def faulted(self, rig_id, now):
        rec = self._rigs.get(rig_id)
        return bool(rec) and len(self._live(rec, now)) >= 2


def mark_duplicates(svc, workers, now=None):
    global _faulted_names
    now = time.time() if now is None else now
    for w in workers:
        rig_id = (w.get("rigforge") or {}).get("rig_id")
        w["duplicate_identity"] = bool(rig_id) and svc._identity.faulted(rig_id, now)
    _faulted_names = frozenset(w.get("name") for w in workers if w["duplicate_identity"])
    return workers
