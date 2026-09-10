# ruff: noqa: F403, F405
from tests.service.notify._alert_service_support import *  # noqa: F403


class TestStackOnline:
    def test_online_fires_once_on_first_cycle(self):
        svc = _svc(announce_online=False)
        assert _keys(_ev(svc)) == [AlertService.EVT_STACK_ONLINE]
        assert _ev(svc) == []  # one-shot — not on later cycles

    def test_online_text_is_friendly(self):
        svc = _svc(announce_online=False)
        _, text = _ev(svc)[0]
        assert "online" in text.lower()
