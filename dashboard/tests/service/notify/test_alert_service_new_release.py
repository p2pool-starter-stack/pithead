# ruff: noqa: F403, F405
from tests.service.notify._alert_service_support import *  # noqa: F403


class TestNewRelease:
    def test_fires_once_on_rising_edge(self):
        svc = _svc()
        assert _ev(svc, update_available=False) == []  # seed
        assert _keys(_ev(svc, update_available=True)) == [AlertService.EVT_NEW_RELEASE]
        assert _ev(svc, update_available=True) == []  # no repeat while still available
