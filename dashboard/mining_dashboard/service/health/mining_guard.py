import os
import time

from mining_dashboard.config.config import NODE_RECOVERY_AFTER_SEC

MINING_GUARD_GRACE_SEC = int(os.environ.get("MINING_GUARD_GRACE_SEC", 600))
P2POOL_ZMQ_STALE_SEC = int(os.environ.get("P2POOL_ZMQ_STALE_SEC", 600))


def monero_trigger(health):
    reasons = health.get("reasons") or []
    return (
        health.get("level") == "red" and bool(reasons),
        "Monero node unhealthy: " + "; ".join(reasons),
        0,
    )


def p2pool_triggers(p2p):
    if not p2p.get("uptime"):
        return {}
    out_peers, in_peers = p2p.get("out_peers", 0), p2p.get("in_peers", 0)
    zmq_age = p2p.get("zmq_active", 0)
    return {
        "p2pool_peers": (
            not out_peers and not in_peers,
            "P2Pool has no sidechain peers",
            MINING_GUARD_GRACE_SEC,
        ),
        "p2pool_zmq": (
            zmq_age > P2POOL_ZMQ_STALE_SEC,
            f"P2Pool has received no ZMQ messages for {int(zmq_age // 60)} min",
            0,
        ),
    }


class MiningGuard:
    def __init__(
        self,
        clock=time.monotonic,
        wall=time.time,
        recovery_after=NODE_RECOVERY_AFTER_SEC,
    ):
        self._clock = clock
        self._wall = wall
        self._recovery_after = recovery_after
        self._holding_since = {}
        self._clear_since = {}
        self.active = {}

    def update(self, triggers):
        now = self._clock()
        for key in set(self._holding_since) | set(self.active) | set(triggers):
            holds, label, grace = triggers.get(key, (False, "", 0))
            if holds:
                self._clear_since.pop(key, None)
                first = self._holding_since.setdefault(key, now)
                if key in self.active:
                    self.active[key]["label"] = label
                elif now - first >= grace:
                    self.active[key] = {"label": label, "since": self._wall()}
                continue
            self._holding_since.pop(key, None)
            if key in self.active:
                first = self._clear_since.setdefault(key, now)
                if now - first >= self._recovery_after:
                    del self.active[key]
                    del self._clear_since[key]

    @property
    def holding(self):
        return bool(self._holding_since) or bool(self.active)

    @property
    def pause(self):
        if not self.active:
            return None
        ordered = sorted(self.active.values(), key=lambda t: t["since"])
        return {
            "reason": "; ".join(t["label"] for t in ordered),
            "since": ordered[0]["since"],
        }
