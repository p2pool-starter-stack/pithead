# ruff: noqa: F403, F405
from tests.service.notify._alert_service_support import *  # noqa: F403


class TestDbReset:
    """One-shot DB-reset alert (#489): fires once when the corrupt-DB auto-heal bumps the counter."""

    def test_fires_once_on_increment(self):
        svc = _svc()
        assert _ev(svc, db_reset_seq=0) == []  # seed silently
        alerts = _ev(svc, db_reset_seq=1, db_reset_detail={"quarantine": "/data/x.corrupt-Z"})
        assert _keys(alerts) == [AlertService.EVT_DB_RESET]
        _, text = alerts[0]
        assert "reset" in text and "/data/x.corrupt-Z" in text
        assert _ev(svc, db_reset_seq=1) == []  # same seq -> no repeat

    def test_seed_nonzero_does_not_replay(self):
        # A restart after a prior reset (counter already >0) must not re-alert.
        svc = _svc()
        assert _ev(svc, db_reset_seq=5) == []
