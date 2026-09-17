from io import StringIO
from unittest.mock import MagicMock, patch

import requests

import mining_dashboard.service.notify.test_alert as test_alert
from mining_dashboard.service.notify.notify_sinks import NtfySink, WebhookSink
from mining_dashboard.service.notify.telegram_notifier import TelegramNotifier


def _response(status):
    response = requests.Response()
    response.status_code = status
    response.url = "https://redacted.invalid"
    return response


def test_unconfigured_sinks_and_healthchecks_are_reported():
    output = StringIO()

    assert test_alert.run_test_alert(TelegramNotifier(), [], output) is True
    assert output.getvalue().splitlines() == [
        "Telegram: not configured",
        "Webhook: not configured",
        "ntfy: not configured",
        "Healthchecks: excluded — a ping moves the dead-man switch.",
    ]


def test_default_path_uses_the_real_sink_factories(monkeypatch):
    notifier_factory = MagicMock(return_value=TelegramNotifier())
    sink = NtfySink("https://ntfy.invalid/topic", tor_proxy="")
    sink.send = MagicMock(return_value=True)
    monkeypatch.setattr(test_alert, "build_default_notifier", notifier_factory)
    monkeypatch.setattr(test_alert, "config_sinks", MagicMock(return_value=[sink]))

    assert test_alert.run_test_alert(output=StringIO()) is True
    notifier_factory.assert_called_once_with()
    test_alert.config_sinks.assert_called_once_with()
    sink.send.assert_called_once_with(test_alert.TEST_MESSAGE, test_alert.TEST_EVENT)


def test_one_failed_sink_does_not_hide_the_other_verdicts_or_secrets():
    token = "TG-SECRET"
    webhook_secret = "HOOK-SECRET"
    ntfy_secret = "NTFY-SECRET"
    notifier = TelegramNotifier(
        enabled=True,
        bot_token=token,
        chat_id="123",
        tor_proxy="",
    )
    sinks = [
        WebhookSink(f"https://refused.invalid/{webhook_secret}", tor_proxy=""),
        WebhookSink("https://rejected.invalid/hook", tor_proxy=""),
        NtfySink("https://ntfy.invalid/topic", token=ntfy_secret, tor_proxy=""),
    ]
    attempts = []

    def post(url, **kwargs):
        attempts.append((url, kwargs))
        if "api.telegram.org" in url:
            raise requests.ConnectionError("refused")
        if "refused.invalid" in url:
            raise requests.Timeout("slow")
        if "rejected.invalid" in url:
            return _response(503)
        return _response(200)

    output = StringIO()
    with patch("requests.post", side_effect=post):
        assert test_alert.run_test_alert(notifier, sinks, output) is False

    text = output.getvalue()
    assert text.splitlines() == [
        "Telegram: FAIL (connection error)",
        "Webhook 1: FAIL (timeout)",
        "Webhook 2: FAIL (HTTP 503)",
        "ntfy: PASS",
        "Healthchecks: excluded — a ping moves the dead-man switch.",
    ]
    assert len(attempts) == 4
    assert attempts[2][1]["json"]["event"] == test_alert.TEST_EVENT
    assert test_alert.TEST_MESSAGE in attempts[-1][1]["data"].decode()
    assert token not in text
    assert webhook_secret not in text
    assert ntfy_secret not in text
    assert "invalid" not in text
