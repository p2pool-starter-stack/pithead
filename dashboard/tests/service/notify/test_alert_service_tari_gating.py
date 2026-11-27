# ruff: noqa: F403, F405
import pytest

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


@pytest.mark.parametrize("required", [False, True])
@pytest.mark.parametrize("rejected", [False, True])
def test_tari_outage_text_matches_policy_and_rejection(required, rejected):
    svc = _svc()
    _ev(svc, tari_required=required)
    alerts = _ev(svc, tari_down=True, tari_required=required, workers_rejected=rejected)
    assert _keys(alerts) == [AlertService.EVT_NODE_DOWN]
    text = alerts[0][1]
    assert "Tari node is DOWN" in text
    assert "workers readmitted" not in text
    if rejected:
        assert "workers rejected — failing over to backup pools" in text
        assert "Monero mining continues" not in text
    elif not required:
        assert "Monero mining continues" in text
        assert "Tari merge mining resumes when the node returns" in text
        assert "backup pools" not in text
    else:
        assert "workers will be rejected if RPC stays unreachable past the outage window" in text
        assert "backup pools" not in text
    assert _ev(svc, tari_down=True, tari_required=required, workers_rejected=rejected) == []

    recovered = _ev(svc, tari_required=required, workers_rejected=False)
    assert _keys(recovered) == [AlertService.EVT_NODE_RECOVERED]
    text = recovered[0][1]
    assert "Tari node recovered" in text
    assert "Tari merge mining resumes" in text
    assert ("workers readmitted" in text) is rejected
    if not required and not rejected:
        assert "Monero mining continues" in text
    assert _ev(svc, tari_required=required) == []


@pytest.mark.parametrize("required", [False, True])
def test_rejection_after_down_alert_is_remembered_at_recovery(required):
    svc = _svc()
    _ev(svc, tari_required=required)
    _ev(svc, tari_down=True, tari_required=required)
    # Successful stop is observed on a later poll, with no duplicate node alert.
    assert _ev(svc, tari_down=True, tari_required=required, workers_rejected=True) == []
    text = _ev(svc, tari_required=required, workers_rejected=False)[0][1]
    assert "workers readmitted" in text
    # The next outage must not inherit rejection from the previous one.
    _ev(svc, tari_down=True, tari_required=required)
    assert "workers readmitted" not in _ev(svc, tari_required=required)[0][1]


@pytest.mark.parametrize("monero_down", [False, True])
def test_recovery_does_not_claim_readmission_while_proxy_remains_stopped(monero_down):
    svc = _svc()
    _ev(svc, monero_down=monero_down)
    _ev(svc, tari_down=True, monero_down=monero_down, workers_rejected=True)
    text = _ev(svc, monero_down=monero_down, workers_rejected=True)[0][1]
    assert "workers remain rejected" in text
    assert "workers readmitted" not in text


def test_restart_during_rejected_outage_seeds_silently_but_remembers_rejection():
    svc = _svc()
    assert _ev(svc, tari_down=True, workers_rejected=True) == []
    assert "workers readmitted" in _ev(svc, workers_rejected=False)[0][1]
