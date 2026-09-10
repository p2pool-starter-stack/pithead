# ruff: noqa: F403, F405
from tests.service.notify._alert_service_support import *  # noqa: F403


class TestTorHealAlert:
    """The #424 self-heal note. Once per outage, sent only after the heal restored the very path
    Telegram rides — so it has no per-event toggle, only the notifier's master switch."""

    async def test_sends_when_notifier_on(self):
        n = _FakeNotifier()
        svc = _svc(notifier=n)
        text = await svc.tor_heal_alert("tor restarted; egress recovered")
        assert text is not None and "tor restarted" in text
        assert n.sent == [text]

    async def test_silent_when_notifier_off(self):
        n = _FakeNotifier(enabled=False)
        svc = _svc(notifier=n)
        assert await svc.tor_heal_alert("tor restarted") is None
        assert n.sent == []
