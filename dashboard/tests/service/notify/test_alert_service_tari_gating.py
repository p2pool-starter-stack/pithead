# ruff: noqa: F403, F405
from tests.service.notify._alert_service_support import *  # noqa: F403


class TestTariGating:
    def test_non_blocking_tari_alerts_and_recovers(self):
        svc = _svc()
        _ev(svc, tari_down=False, tari_required=False)
        assert _keys(_ev(svc, tari_down=True, tari_required=False)) == [AlertService.EVT_NODE_DOWN]
        assert _ev(svc, tari_down=True, tari_required=False) == []
        assert _keys(_ev(svc, tari_down=False, tari_required=False)) == [
            AlertService.EVT_NODE_RECOVERED
        ]

    def test_no_stale_edge_when_tari_becomes_required(self):
        # Changing the failover policy must not replay an already delivered outage alert.
        svc = _svc()
        _ev(svc, tari_down=False, tari_required=False)
        _ev(svc, tari_down=True, tari_required=False)  # alerts once
        assert _ev(svc, tari_down=True, tari_required=True) == []
        # ...but a genuine recovery from there still fires.
        assert _keys(_ev(svc, tari_down=False, tari_required=True)) == [
            AlertService.EVT_NODE_RECOVERED
        ]

    def test_required_tari_alerts(self):
        svc = _svc()
        _ev(svc, tari_down=False, tari_required=True)
        _, text = _ev(svc, tari_down=True, tari_required=True)[0]
        assert "Tari" in text
