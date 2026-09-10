# ruff: noqa: F403, F405
from tests.service.notify._alert_service_support import *  # noqa: F403


class TestDegradationAlert:
    """The #99 hashrate-loss / recovery push. The DegradationMonitor owns the debounce; this only
    formats + sends, tallies the loss as an incident, and honours the event toggle."""

    async def test_loss_sends_and_records_incident(self):
        n = _FakeNotifier()
        svc = _svc(notifier=n)
        text = await svc.degradation_alert("loss", 0.62)
        assert "62%" in text and "dropped" in text.lower()
        assert n.sent == [text]
        assert svc.drain_incidents() == {AlertService.EVT_HASHRATE_LOSS: 1}

    async def test_recovery_sends_no_incident(self):
        n = _FakeNotifier()
        svc = _svc(notifier=n)
        text = await svc.degradation_alert("recovered", 0.0)
        assert "recovered" in text.lower()
        assert n.sent == [text]
        assert svc.drain_incidents() == {}  # recovery is not an incident

    async def test_gated_off_still_records_loss(self):
        # Toggle off suppresses the message but the incident is still tallied for the daily log.
        n = _FakeNotifier(allow=set())
        svc = _svc(notifier=n)
        assert await svc.degradation_alert("loss", 0.5) is None
        assert n.sent == []
        assert svc.drain_incidents() == {AlertService.EVT_HASHRATE_LOSS: 1}
