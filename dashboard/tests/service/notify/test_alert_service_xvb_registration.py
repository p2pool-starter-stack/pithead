# ruff: noqa: F403, F405
from tests.service.notify._alert_service_support import *  # noqa: F403


class TestXvbRegistration:
    def test_invalid_then_recovered(self):
        svc = _svc()
        assert _ev(svc, xvb_enabled=True, xvb_registration_state="registered") == []  # seed
        assert _keys(_ev(svc, xvb_enabled=True, xvb_registration_state="invalid")) == [
            AlertService.EVT_XVB_REGISTRATION
        ]
        assert _keys(_ev(svc, xvb_enabled=True, xvb_registration_state="registered")) == [
            AlertService.EVT_XVB_REGISTRATION
        ]

    def test_failing_alerts(self):
        svc = _svc()
        _ev(svc, xvb_enabled=True, xvb_registration_state="registered")
        _, text = _ev(svc, xvb_enabled=True, xvb_registration_state="failing")[0]
        assert "failing" in text.lower()

    def test_silent_while_disabled(self):
        svc = _svc()
        assert _ev(svc, xvb_enabled=False, xvb_registration_state="invalid") == []

    def test_benign_transition_is_silent(self):
        # A change that isn't into invalid/failing (nor recovering from one) doesn't alert.
        svc = _svc()
        _ev(svc, xvb_enabled=True, xvb_registration_state="registered")  # seed
        assert _ev(svc, xvb_enabled=True, xvb_registration_state="") == []
