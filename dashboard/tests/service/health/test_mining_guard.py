import pytest

from mining_dashboard.service.health import mining_guard
from mining_dashboard.service.health.mining_guard import (
    MiningGuard,
    monero_trigger,
    p2pool_triggers,
)


class Clock:
    def __init__(self):
        self.now = 0

    def __call__(self):
        return self.now


@pytest.fixture
def clock():
    return Clock()


@pytest.fixture
def guard(clock):
    return MiningGuard(clock=clock, wall=lambda: 1000 + clock.now, recovery_after=60)


def trig(holds, grace=600, label="bad"):
    return {"x": (holds, label, grace)}


class TestGuard:
    def test_brief_dip_inside_grace_never_activates(self, guard, clock):
        guard.update(trig(True))
        clock.now = 599
        guard.update(trig(True))
        assert guard.active == {} and guard.holding
        clock.now = 600
        guard.update(trig(False))
        assert guard.active == {} and not guard.holding and guard.pause is None

    def test_activates_after_grace_and_names_trigger_and_since(self, guard, clock):
        guard.update(trig(True, label="P2Pool has no sidechain peers"))
        clock.now = 600
        guard.update(trig(True, label="P2Pool has no sidechain peers"))
        assert guard.pause == {"reason": "P2Pool has no sidechain peers", "since": 1600}

    def test_zero_grace_activates_immediately(self, guard):
        guard.update(trig(True, grace=0))
        assert guard.pause["reason"] == "bad"

    def test_clears_only_after_recovery_window(self, guard, clock):
        guard.update(trig(True, grace=0))
        clock.now = 10
        guard.update(trig(False))
        assert guard.active
        clock.now = 69
        guard.update(trig(False))
        assert guard.active
        clock.now = 70
        guard.update(trig(False))
        assert guard.active == {} and not guard.holding

    def test_relapse_during_recovery_restarts_the_window(self, guard, clock):
        guard.update(trig(True, grace=0))
        clock.now = 10
        guard.update(trig(False))
        clock.now = 50
        guard.update(trig(True))
        clock.now = 100
        guard.update(trig(False))
        clock.now = 159
        guard.update(trig(False))
        assert guard.active
        clock.now = 160
        guard.update(trig(False))
        assert guard.active == {}

    def test_omitted_trigger_counts_as_clear(self, guard, clock):
        guard.update(trig(True, grace=0))
        clock.now = 60
        guard.update({})
        guard.update({})
        clock.now = 120
        guard.update({})
        assert guard.active == {}

    def test_pause_joins_reasons_oldest_first(self, guard, clock):
        guard.update({"a": (True, "first", 0)})
        clock.now = 5
        guard.update({"a": (True, "first", 0), "b": (True, "second", 0)})
        assert guard.pause == {"reason": "first; second", "since": 1000}


class TestMoneroTrigger:
    def test_red_verdict_holds_with_its_reasons(self):
        health = {"level": "red", "reasons": ["0 outgoing peers for 12 min"]}
        assert monero_trigger(health) == (
            True,
            "Monero node unhealthy: 0 outgoing peers for 12 min",
            0,
        )

    @pytest.mark.parametrize("level", ["green", "unknown"])
    def test_other_levels_do_not_hold(self, level):
        assert monero_trigger({"level": level, "reasons": []})[0] is False

    def test_missing_verdict_does_not_hold(self):
        assert monero_trigger({})[0] is False


class TestP2PoolTriggers:
    def base(self, **kw):
        return {"uptime": 900, "out_peers": 3, "in_peers": 1, "zmq_active": 4, **kw}

    def test_connected_p2pool_holds_nothing(self):
        assert not any(h for h, _, _ in p2pool_triggers(self.base()).values())

    def test_no_peers_either_way_holds_with_the_grace(self):
        holds, label, grace = p2pool_triggers(self.base(out_peers=0, in_peers=0))["p2pool_peers"]
        assert holds and "no sidechain peers" in label
        assert grace == mining_guard.MINING_GUARD_GRACE_SEC

    def test_one_inbound_peer_is_not_isolated(self):
        assert not p2pool_triggers(self.base(out_peers=0, in_peers=2))["p2pool_peers"][0]

    def test_stale_zmq_holds(self):
        holds, label, _ = p2pool_triggers(self.base(zmq_active=3600))["p2pool_zmq"]
        assert holds and "no ZMQ messages for 60 min" in label

    def test_zmq_at_the_bound_is_fine(self):
        zmq = self.base(zmq_active=mining_guard.P2POOL_ZMQ_STALE_SEC)
        assert not p2pool_triggers(zmq)["p2pool_zmq"][0]

    @pytest.mark.parametrize("p2p", [{}, {"uptime": 0, "out_peers": 0, "in_peers": 0}])
    def test_absent_stats_are_no_verdict(self, p2p):
        assert p2pool_triggers(p2p) == {}
