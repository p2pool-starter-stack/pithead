import logging

import pytest

from mining_dashboard.service.notify.alert_levels import (
    ALL_EVENTS,
    ALWAYS_ON_EVENTS,
    CRITICAL_EVENTS,
    IMPORTANT_EVENTS,
    LEVEL_EVENTS,
    level_delivers,
    normalize_level,
)
from mining_dashboard.service.notify.notify_sinks import NtfySink, WebhookSink
from mining_dashboard.service.notify.telegram_notifier import TelegramNotifier
from tests.service.notify._alert_service_support import AlertService, _svc

EVENTS = {v for k, v in vars(AlertService).items() if k.startswith("EVT_")}
OPTIONAL = EVENTS - ALWAYS_ON_EVENTS


def _tg(level, key="t", chat="1"):
    return TelegramNotifier(bot_token=key, chat_id=chat, level=level, tor_proxy="")


def test_table_sizes_match_the_ruling():
    assert len(CRITICAL_EVENTS) == 6
    assert len(IMPORTANT_EVENTS - CRITICAL_EVENTS) == 13
    assert len(ALL_EVENTS - IMPORTANT_EVENTS) == 6
    assert ALWAYS_ON_EVENTS == {"wallet_changed", "clearnet_exposed", "payout_wallet_down"}


@pytest.mark.parametrize(
    ("level", "expected"),
    [("critical", CRITICAL_EVENTS), ("important", IMPORTANT_EVENTS), ("all", ALL_EVENTS)],
)
def test_delivered_optional_events_equal_the_table(level, expected):
    assert {e for e in OPTIONAL if _tg(level).event_enabled(e)} == expected


@pytest.mark.parametrize("level", ["off", "", None])
def test_off_and_absent_deliver_no_optional_event(level):
    assert not any(_tg(level).event_enabled(e) for e in OPTIONAL)


def test_unknown_level_falls_back_to_all_with_a_log_line(caplog):
    with caplog.at_level(logging.WARNING, logger="AlertLevels"):
        assert normalize_level("loud") == "all"
    assert "loud" in caplog.text
    assert {e for e in OPTIONAL if level_delivers("loud", e)} == ALL_EVENTS


@pytest.mark.parametrize("level", ["off", "critical", "important", "all", "bogus", None])
def test_always_on_events_are_delivered_at_every_level(level):
    assert all(_tg(level).event_enabled(e) for e in ALWAYS_ON_EVENTS)


@pytest.mark.parametrize("level", ["off", "critical", "important", "all"])
@pytest.mark.parametrize(("token", "chat"), [("", "1"), ("t", ""), ("", "")])
def test_nothing_reaches_telegram_without_both_credentials(level, token, chat):
    notifier = _tg(level, token, chat)
    assert notifier.enabled is False
    assert not any(notifier.event_enabled(e) for e in EVENTS)


@pytest.mark.parametrize("level", ["off", "critical", "important", "all"])
async def test_webhook_and_ntfy_receive_every_event_at_every_level(level, monkeypatch):
    tg, hook, ntfy = (
        _tg(level),
        WebhookSink("https://hook.invalid/x"),
        NtfySink("https://ntfy.invalid/t"),
    )
    for sink in (hook, ntfy):
        assert all(sink.event_enabled(e) for e in EVENTS)
    sent = []
    for sink in (tg, hook, ntfy):
        monkeypatch.setattr(
            sink, "send", lambda text, event="", s=sink: sent.append((s, event)) or True
        )
    svc = _svc(notifier=tg, sinks=[tg, hook, ntfy])
    await svc.raffle_win_alert("mini", 1000)
    reached = {s for s, _ in sent}
    assert {hook, ntfy} <= reached
    assert (tg in reached) == (AlertService.EVT_RAFFLE_WIN in LEVEL_EVENTS[level])


@pytest.mark.parametrize("level", ["off", "critical"])
async def test_payout_wallet_down_reaches_telegram_at_low_levels(level, monkeypatch):
    tg = _tg(level)
    sent = []
    monkeypatch.setattr(tg, "send", lambda text, event="": sent.append(event) or True)
    await _svc(notifier=tg, sinks=[tg]).payout_wallet_down_alert("monero", "is unreachable")
    assert sent == [AlertService.EVT_PAYOUT_WALLET_DOWN]
