# ruff: noqa: F403, F405
from tests.service.notify._alert_service_support import *  # noqa: F403


class TestDbEdges:
    def test_unhealthy_then_recovered(self):
        svc = _svc()
        assert _ev(svc, db_healthy=True) == []  # seed
        assert _keys(_ev(svc, db_healthy=False)) == [AlertService.EVT_DB_UNHEALTHY]
        assert _ev(svc, db_healthy=False) == []  # no repeat
        _, text = _ev(svc, db_healthy=True)[0]
        assert "recovered" in text
