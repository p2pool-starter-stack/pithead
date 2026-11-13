import time

from mining_dashboard.config.config import (
    MINING_GUARD_GRACE_SEC,
    NODE_DOWN_AFTER_SEC,
    NODE_RECOVERY_AFTER_SEC,
    P2POOL_LAG_BLOCKS,
    P2POOL_ZMQ_STALE_SEC,
)

LAG_STALL_SEC = 900
GUARDED_CONTAINERS = (("monerod", "Monero node"), ("p2pool", "P2Pool"), ("tor", "Tor"))


def monero_triggers(health, sync):
    reasons = health.get("reasons") or []
    return {
        "monero_unhealthy": (
            health.get("level") == "red" and bool(reasons),
            "Monero node unhealthy: " + "; ".join(reasons),
            0,
        ),
        "monero_peers": (
            health.get("peers_out") == 0,
            "Monero node has 0 outgoing peers",
            MINING_GUARD_GRACE_SEC,
        ),
        "monero_unsynced": (
            sync.get("synchronized") is False,
            "Monero node reports it is not synchronized",
            MINING_GUARD_GRACE_SEC,
        ),
    }


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
            NODE_DOWN_AFTER_SEC,
        ),
    }


def lag_trigger(lag, advance_age):
    return {
        "p2pool_lag": (
            lag is not None and lag >= P2POOL_LAG_BLOCKS and (advance_age or 0) >= LAG_STALL_SEC,
            f"Monero node is {lag} blocks behind P2Pool's peers",
            NODE_DOWN_AFTER_SEC,
        )
    }


def container_triggers(states):
    triggers = {}
    for name, label in GUARDED_CONTAINERS:
        state = states.get(name)
        if state is None:
            continue
        if not state["running"]:
            problem = "is not running"
        elif state["restarting"]:
            problem = "is restarting"
        elif state["health"] in ("starting", "unhealthy"):
            problem = f"is {state['health']}"
        else:
            problem = None
        triggers[f"{name}_container"] = (
            problem is not None,
            f"{label} container {problem}",
            NODE_DOWN_AFTER_SEC,
        )
    return triggers


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
        self._holding_wall = {}
        self._clear_since = {}
        self.active = {}

    def update(self, triggers):
        now = self._clock()
        for key in set(self._holding_since) | set(self.active) | set(triggers):
            holds, label, grace = triggers.get(key, (False, "", 0))
            if holds:
                self._clear_since.pop(key, None)
                first = self._holding_since.setdefault(key, now)
                since = self._holding_wall.setdefault(key, self._wall())
                if key in self.active:
                    self.active[key]["label"] = label
                elif now - first >= grace:
                    self.active[key] = {"label": label, "since": since}
                continue
            self._holding_since.pop(key, None)
            self._holding_wall.pop(key, None)
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
