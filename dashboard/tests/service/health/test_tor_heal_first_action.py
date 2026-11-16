"""Tor egress healer: the first NEWNYM comes inside the owner's alert window."""

from mining_dashboard.service.health.tor_heal import (
    COOLDOWN_SEC,
    PROBE_INTERVAL_SEC,
    TorEgressHealer,
)


class _Clock:
    t = 1000.0

    def __call__(self):
        return self.t


def _healer(clock):
    return TorEgressHealer(
        docker_control=None,
        enabled=True,
        probe=lambda: (False, "test probe"),
        clock=clock,
        restart_monerod=False,
    )


class TestFirstAction:
    def test_first_nondisruptive_action_comes_within_five_minutes(self):
        clock = _Clock()
        h = _healer(clock)
        h.decide(False, clock.t)
        clock.t += PROBE_INTERVAL_SEC
        assert PROBE_INTERVAL_SEC <= 5 * 60
        assert h.decide(False, clock.t) == "heal"
        assert h._attempts == 1

    def test_later_actions_keep_the_longer_threshold(self):
        clock = _Clock()
        h = _healer(clock)
        h.decide(False, clock.t)
        clock.t += 15 * 60
        assert h.decide(False, clock.t) == "heal"
        clock.t += COOLDOWN_SEC
        assert h.decide(False, clock.t) == "heal"
        assert h._failing_since is not None
        assert h._attempts == 2
