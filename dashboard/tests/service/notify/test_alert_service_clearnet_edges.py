# ruff: noqa: F403, F405
from tests.service.notify._alert_service_support import *  # noqa: F403


class TestClearnetEdges:
    def test_exposed_then_reverted(self):
        svc = _svc()
        assert _ev(svc, clearnet_active=False) == []  # seed
        assert _keys(_ev(svc, clearnet_active=True)) == [AlertService.EVT_CLEARNET_EXPOSED]
        assert _ev(svc, clearnet_active=True) == []  # no repeat
        _, text = _ev(svc, clearnet_active=False)[0]
        assert "Tor-only" in text
