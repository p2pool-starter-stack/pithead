"""Tor egress healer: the first NEWNYM comes inside the owner's alert window."""

from mining_dashboard.service.health.tor_heal import (
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
        assert h.decide(False, clock.t) == "heal"
        assert h._attempts == 1

    def test_a_ping_failing_for_five_minutes_counts_toward_the_first_action(self):
        clock = _Clock()
        ping_since = [clock.t - 4 * 60]
        h = TorEgressHealer(
            docker_control=None,
            enabled=True,
            probe=lambda: (False, "test probe"),
            clock=clock,
            restart_monerod=False,
            ping_failing_since=lambda: ping_since[0],
        )
        assert h.decide(False, clock.t) is None
        clock.t += 60
        assert h.decide(False, clock.t) == "heal"

    def test_no_ping_failure_leaves_the_probe_streak_alone(self):
        clock = _Clock()
        h = TorEgressHealer(
            docker_control=None,
            enabled=True,
            probe=lambda: (False, "test probe"),
            clock=clock,
            restart_monerod=False,
            ping_failing_since=lambda: None,
        )
        h.decide(False, clock.t)
        clock.t += 60
        assert h.decide(False, clock.t) is None
