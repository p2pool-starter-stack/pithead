# ruff: noqa: F403, F405
from tests.service.notify._alert_service_support import *  # noqa: F403


class TestSinkFanout:
    """Multi-sink dispatch (#380): every alert reaches every sink that carries its event."""

    async def test_alert_reaches_every_sink(self):
        tg, hook = _FakeNotifier(), _FakeNotifier()
        svc = _svc(notifier=tg, sinks=[tg, hook])
        await svc.process(monero_down=False, **_PROCESS_SIGNALS)  # seed
        out = await svc.process(monero_down=True, **_PROCESS_SIGNALS)
        assert _keys(out) == [AlertService.EVT_NODE_DOWN]
        for sink in (tg, hook):
            assert len(sink.sent) == 1 and "DOWN" in sink.sent[0]
            assert sink.sent_events == [AlertService.EVT_NODE_DOWN]

    async def test_telegram_disabled_webhook_still_delivers(self):
        # A webhook-only stack (Telegram unconfigured) must still alert — `enabled` is any-sink.
        tg, hook = _FakeNotifier(enabled=False), _FakeNotifier()
        svc = _svc(notifier=tg, sinks=[tg, hook])
        assert svc.enabled is True
        await svc.process(monero_down=False, **_PROCESS_SIGNALS)
        out = await svc.process(monero_down=True, **_PROCESS_SIGNALS)
        assert _keys(out) == [AlertService.EVT_NODE_DOWN]
        assert tg.sent == [] and len(hook.sent) == 1

    async def test_per_event_toggle_silences_only_that_sink(self):
        # Telegram's node_down toggled off silences Telegram; the webhook (no per-event
        # toggles) still gets the alert.
        tg, hook = _FakeNotifier(allow=set()), _FakeNotifier()
        svc = _svc(notifier=tg, sinks=[tg, hook])
        await svc.process(monero_down=False, **_PROCESS_SIGNALS)
        out = await svc.process(monero_down=True, **_PROCESS_SIGNALS)
        assert _keys(out) == [AlertService.EVT_NODE_DOWN]
        assert tg.sent == [] and len(hook.sent) == 1

    async def test_all_sinks_disabled_is_noop(self):
        tg, hook = _FakeNotifier(enabled=False), _FakeNotifier(enabled=False)
        svc = _svc(notifier=tg, sinks=[tg, hook])
        assert svc.enabled is False
        await svc.process(monero_down=True, **_PROCESS_SIGNALS)
        out = await svc.process(monero_down=True, **_PROCESS_SIGNALS)
        assert out == [] and tg.sent == [] and hook.sent == []

    async def test_degradation_alert_fans_out(self):
        tg, hook = _FakeNotifier(enabled=False), _FakeNotifier()
        svc = _svc(notifier=tg, sinks=[tg, hook])
        text = await svc.degradation_alert("loss", 0.5)
        assert text and tg.sent == []
        assert hook.sent == [text]
        assert hook.sent_events == [AlertService.EVT_HASHRATE_LOSS]

    async def test_payout_confirmed_alert_fans_out(self):
        # #381: fans to every sink that carries payout_confirmed, carries the chain + short txid,
        # and formats atomic→XMR. Telegram off, webhook on → only the webhook receives it.
        tg, hook = _FakeNotifier(enabled=False), _FakeNotifier()
        svc = _svc(notifier=tg, sinks=[tg, hook])
        text = await svc.payout_confirmed_alert("monero", 250_000_000_000, "abcdef1234567890")
        assert text and tg.sent == []
        assert hook.sent == [text]
        assert hook.sent_events == [AlertService.EVT_PAYOUT_CONFIRMED]
        assert "0.250000" in text and "MONERO" in text and "abcdef12" in text
        # The full txid is never put in the message — only the 8-char prefix.
        assert "abcdef1234567890" not in text

    async def test_payout_confirmed_alert_noop_when_toggled_off(self):
        # Event toggled off on the only sink → no send, returns None (the caller still records it).
        hook = _FakeNotifier(allow=set())  # enabled transport, but no events allowed
        svc = _svc(notifier=hook, sinks=[hook])
        assert await svc.payout_confirmed_alert("monero", 1, "tx") is None
        assert hook.sent == []

    async def test_payout_confirmed_alert_tari_uses_microtari_divisor(self):
        # #462: the shared alert must format Tari amounts as microTari (÷1e6), not piconero (÷1e12).
        # 250_000 µT = 0.25 XTM; the label reads TARI.
        hook = _FakeNotifier()
        svc = _svc(notifier=hook, sinks=[hook])
        text = await svc.payout_confirmed_alert("tari", 250_000, "abcdef1234567890")
        assert text and "0.250000" in text and "TARI" in text and "abcdef12" in text
        assert "abcdef1234567890" not in text  # only the 8-char prefix, never the full txid

    async def test_raffle_win_alert_fans_out(self):
        # Fans to every sink carrying raffle_win, with the round type and the credited hashrate
        # formatted like the dashboard. Telegram off, webhook on → only the webhook receives it.
        tg, hook = _FakeNotifier(enabled=False), _FakeNotifier()
        svc = _svc(notifier=tg, sinks=[tg, hook])
        text = await svc.raffle_win_alert("donor_whale", 4.2e6)
        assert text and tg.sent == []
        assert hook.sent == [text]
        assert hook.sent_events == [AlertService.EVT_RAFFLE_WIN]
        assert "donor_whale" in text and "4.20 MH/s" in text

    async def test_raffle_win_alert_noop_when_toggled_off(self):
        hook = _FakeNotifier(allow=set())  # enabled transport, but no events allowed
        svc = _svc(notifier=hook, sinks=[hook])
        assert await svc.raffle_win_alert("donor", 1000.0) is None
        assert hook.sent == []

    async def test_default_sinks_are_just_the_notifier(self):
        # No webhook/ntfy config in the test env → the sink list is exactly [notifier], so the
        # default stack's behaviour is unchanged.
        tg = _FakeNotifier()
        svc = _svc(notifier=tg)
        assert svc.sinks == [tg]
