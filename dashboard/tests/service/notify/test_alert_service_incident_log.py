# ruff: noqa: F403, F405
from tests.service.notify._alert_service_support import *  # noqa: F403


class TestIncidentLog:
    def test_tallies_problems_and_drains(self):
        svc = _svc()
        _ev(svc, monero_down=False)  # seed
        _ev(svc, monero_down=True)  # +node_down
        _ev(svc, db_healthy=True)  # seed
        _ev(svc, db_healthy=False)  # +db_unhealthy
        _ev(svc, disk_percent=50)  # seed
        _ev(svc, disk_percent=97)  # +disk_space (critical)
        assert svc.drain_incidents() == {
            "node_down": 1,
            "db_unhealthy": 1,
            "disk_space": 1,
        }
        assert svc.drain_incidents() == {}  # drained → reset

    def test_recoveries_are_not_incidents(self):
        svc = _svc()
        _ev(svc, monero_down=False)
        _ev(svc, monero_down=True)  # +1
        _ev(svc, monero_down=False)  # recovery — not counted
        assert svc.drain_incidents() == {"node_down": 1}

    def test_worker_offline_counts_once(self, _down, _on):
        svc = _svc()
        _ev(svc, workers=_on("r"), workers_expected=True, now=0)  # prime
        _ev(svc, workers=_down("r"), workers_expected=True, now=0)  # DOWN streak
        _ev(svc, workers=_down("r"), workers_expected=True, now=300)  # offline → incident
        _ev(svc, workers=_on("r"), workers_expected=True, now=300)  # back online
        _ev(svc, workers=_on("r"), workers_expected=True, now=420)  # recovered — not counted
        assert svc.drain_incidents() == {"worker_offline": 1}
