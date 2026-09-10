# ruff: noqa: F403, F405
from tests.service.notify._alert_service_support import *  # noqa: F403


class TestHostLabel:
    def test_prefixes_when_set(self):
        svc = _svc(host_label="box.lan")
        _ev(svc, monero_down=False)
        _, text = _ev(svc, monero_down=True)[0]
        assert text.startswith("[box.lan] ")

    def test_placeholder_host_is_not_prefixed(self):
        svc = _svc(host_label="Unknown Host")
        _ev(svc, monero_down=False)
        _, text = _ev(svc, monero_down=True)[0]
        assert not text.startswith("[")
