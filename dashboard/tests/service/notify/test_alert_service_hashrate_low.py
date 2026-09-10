# ruff: noqa: F403, F405
from tests.service.notify._alert_service_support import *  # noqa: F403


class TestHashrateLow:
    def test_warns_then_recovers(self):
        svc = _svc()
        assert _ev(svc, low_hr_warning=False) == []  # seed
        assert _keys(_ev(svc, low_hr_warning=True)) == [AlertService.EVT_HASHRATE_LOW]
        assert _ev(svc, low_hr_warning=True) == []  # no repeat
        _, text = _ev(svc, low_hr_warning=False)[0]
        assert "back above" in text
