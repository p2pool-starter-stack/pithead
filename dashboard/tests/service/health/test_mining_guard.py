import pytest

from mining_dashboard.service.health import mining_guard
from mining_dashboard.service.health.mining_guard import (
    MiningGuard,
    container_triggers,
    lag_trigger,
    monero_triggers,
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
        assert guard.pause == {"reason": "P2Pool has no sidechain peers", "since": 1000}

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

    def test_since_is_the_onset_not_the_activation(self, guard, clock):
        clock.now = 100
        guard.update(trig(True, grace=300))
        clock.now = 400
        guard.update(trig(True, grace=300))
        assert guard.pause["since"] == 1100


class TestMoneroTriggers:
    def test_red_verdict_holds_with_its_reasons(self):
        health = {"level": "red", "reasons": ["0 outgoing peers for 12 min"]}
        holds, label, grace = monero_triggers(health, {})["monero_unhealthy"]
        assert holds and grace == 0
        assert label == "Monero node unhealthy: 0 outgoing peers for 12 min"

    @pytest.mark.parametrize("level", ["green", "unknown"])
    def test_other_levels_do_not_hold(self, level):
        assert monero_triggers({"level": level, "reasons": []}, {})["monero_unhealthy"][0] is False

    def test_zero_outgoing_peers_holds_at_once_with_the_grace(self):
        holds, _, grace = monero_triggers({"peers_out": 0}, {})["monero_peers"]
        assert holds and grace == mining_guard.MINING_GUARD_GRACE_SEC

    @pytest.mark.parametrize("peers", [None, 3])
    def test_unknown_or_present_peers_do_not_hold(self, peers):
        assert monero_triggers({"peers_out": peers}, {})["monero_peers"][0] is False

    @pytest.mark.parametrize("synchronized,holds", [(False, True), (True, False), (None, False)])
    def test_node_reporting_unsynchronized_holds(self, synchronized, holds):
        sync = {"synchronized": synchronized}
        assert monero_triggers({}, sync)["monero_unsynced"][0] is holds


class TestLagTrigger:
    def test_lag_with_a_stalled_tip_holds(self):
        holds, label, _ = lag_trigger(480, 900)["p2pool_lag"]
        assert holds and "480 blocks behind" in label

    @pytest.mark.parametrize("lag,age", [(4, 900), (480, 120), (480, None), (None, 900), (0, 900)])
    def test_no_hold_without_both_lag_and_a_stalled_tip(self, lag, age):
        assert lag_trigger(lag, age)["p2pool_lag"][0] is False


def state(running=True, restarting=False, health="healthy"):
    return {"running": running, "restarting": restarting, "health": health}


class TestContainerTriggers:
    def test_healthy_containers_hold_nothing(self):
        states = {n: state() for n in ("monerod", "p2pool", "tor")}
        assert not any(h for h, _, _ in container_triggers(states).values())

    @pytest.mark.parametrize(
        "name,kwargs,needle",
        [
            ("monerod", {"running": False}, "Monero node container is not running"),
            ("p2pool", {"restarting": True}, "P2Pool container is restarting"),
            ("tor", {"health": "starting"}, "Tor container is starting"),
            ("tor", {"health": "unhealthy"}, "Tor container is unhealthy"),
        ],
    )
    def test_each_failure_names_its_container(self, name, kwargs, needle):
        holds, label, _ = container_triggers({name: state(**kwargs)})[f"{name}_container"]
        assert holds and label == needle

    def test_container_without_a_healthcheck_is_judged_on_running_only(self):
        assert container_triggers({"tor": state(health=None)})["tor_container"][0] is False

    def test_absent_container_is_no_verdict(self):
        assert container_triggers({}) == {}


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

    def test_zmq_waits_for_its_grace(self):
        assert (
            p2pool_triggers(self.base(zmq_active=3600))["p2pool_zmq"][2]
            == mining_guard.NODE_DOWN_AFTER_SEC
        )

    def test_zmq_at_the_bound_is_fine(self):
        zmq = self.base(zmq_active=mining_guard.P2POOL_ZMQ_STALE_SEC)
        assert not p2pool_triggers(zmq)["p2pool_zmq"][0]

    @pytest.mark.parametrize("p2p", [{}, {"uptime": 0, "out_peers": 0, "in_peers": 0}])
    def test_absent_stats_are_no_verdict(self, p2p):
        assert p2pool_triggers(p2p) == {}


class TestRealSources:
    def test_monero_triggers_read_a_real_peerless_verdict(self):
        from mining_dashboard.service.health.monero_health import MoneroChainHealth

        now = [0]
        chain = MoneroChainHealth(clock=lambda: now[0])
        sync = {"reachable": True, "height": 10, "peers_out": 0, "peers_in": 0, "is_syncing": False}
        health = chain.observe(sync)
        triggers = monero_triggers(health, sync)
        assert triggers["monero_unhealthy"][0] is False
        assert triggers["monero_peers"][0] is True
        now[0] = 700
        holds, label, _ = monero_triggers(chain.observe(sync), sync)["monero_unhealthy"]
        assert holds and "0 outgoing peers" in label
