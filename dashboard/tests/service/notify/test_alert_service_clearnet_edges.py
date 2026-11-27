# ruff: noqa: F403, F405
from tests.service.notify._alert_service_support import *  # noqa: F403


class TestClearnetEdges:
    def test_exposed_then_reverted(self):
        svc = _svc()
        assert _ev(svc, clearnet_active=False) == []  # seed
        ((key, warning),) = _ev(svc, clearnet_active=True)
        assert key == AlertService.EVT_CLEARNET_EXPOSED
        assert "host verifies the Tor switch and firewall" in warning
        assert _ev(svc, clearnet_active=True) == []  # no repeat
        _, text = _ev(svc, clearnet_active=False)[0]
        assert "Tor-only" in text
        assert "host verified the running daemon and closed firewall exception" in text
