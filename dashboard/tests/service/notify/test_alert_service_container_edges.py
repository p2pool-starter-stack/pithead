# ruff: noqa: F403, F405
from tests.service.notify._alert_service_support import *  # noqa: F403


class TestContainerEdges:
    """#337: container crash-loop / stuck-unhealthy / recovered off the read-proxy inspects."""

    def test_crash_loop_message_names_the_container(self):
        svc = _svc(container_monitor=_StubContainerMonitor([("p2pool", "crash_loop")]))
        alerts = _ev(svc, containers={})
        assert _keys(alerts) == [AlertService.EVT_CONTAINER_UNHEALTHY]
        assert "p2pool" in alerts[0][1] and "docker logs p2pool" in alerts[0][1]

    def test_unhealthy_and_recovered_messages(self):
        svc = _svc(
            container_monitor=_StubContainerMonitor(
                [("monerod", "unhealthy"), ("tari", "recovered")]
            )
        )
        alerts = _ev(svc, containers={})
        assert _keys(alerts) == [AlertService.EVT_CONTAINER_UNHEALTHY] * 2
        assert "monerod" in alerts[0][1] and "unhealthy" in alerts[0][1]
        assert "tari" in alerts[1][1] and "recovered" in alerts[1][1]

    def test_problem_edges_are_incidents_recovery_is_not(self):
        svc = _svc(
            container_monitor=_StubContainerMonitor(
                [("p2pool", "crash_loop"), ("monerod", "unhealthy"), ("tari", "recovered")]
            )
        )
        _ev(svc, containers={})
        assert svc.drain_incidents() == {"container_unhealthy": 2}

    def test_none_is_no_data_and_skips_the_monitor(self):
        # containers=None (collector skipped) is no verdict — the monitor isn't fed, so its
        # streak state stays put rather than aging on missing data.
        monitor = _StubContainerMonitor([("p2pool", "crash_loop")])
        svc = _svc(container_monitor=monitor)
        assert _ev(svc, containers=None) == []
        assert monitor.fed == []

    def test_toggle_off_filters_every_edge(self):
        svc = _svc(
            notifier=_FakeNotifier(allow=set()),
            container_monitor=_StubContainerMonitor([("p2pool", "crash_loop")]),
        )
        assert _ev(svc, containers={}) == []

    def test_real_monitor_wiring_uses_now(self):
        # End-to-end through evaluate() with the real monitor: a restarting container on two
        # consecutive cycles is a crash-loop edge; the injected `now` drives its clock.
        svc = _svc()
        s = {"restart_count": 0, "restarting": True, "health": None, "running": True}
        assert _ev(svc, containers={"tari": {**s, "restarting": False}}, now=0) == []  # seed
        assert _ev(svc, containers={"tari": s}, now=30) == []
        assert _keys(_ev(svc, containers={"tari": s}, now=60)) == [
            AlertService.EVT_CONTAINER_UNHEALTHY
        ]
