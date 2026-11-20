import io
import json
import socket
import sys
from types import SimpleNamespace

import pytest

from mining_dashboard.client.xvb_client import XvbClient
from mining_dashboard.service.health import tari_health
from mining_dashboard.service.health.update_checker import GitHubReleaseClient
from mining_dashboard.service.notify import healthchecks_child
from mining_dashboard.service.notify import telegram_commands as tc
from mining_dashboard.service.notify.notify_sinks import NtfySink, WebhookSink
from mining_dashboard.service.notify.telegram_notifier import TelegramNotifier
from mining_dashboard.service.xvb.price_feed import CoinGeckoClient

WALLET = "4" + "A" * 94


@pytest.fixture
def sockets(monkeypatch):
    opened = []

    def record(*args, **kwargs):
        opened.append(args)
        raise OSError("socket blocked")

    monkeypatch.setattr(socket, "socket", record)
    monkeypatch.setattr(socket, "create_connection", record)
    monkeypatch.setattr(socket, "getaddrinfo", record)
    return opened


def _bot():
    ds = SimpleNamespace(latest_data={}, state_manager=object())
    return tc.TelegramCommandBot(ds, enabled=True, bot_token="tok", chat_id="42", tor_proxy="")


def _tari(monkeypatch):
    monkeypatch.setattr(tari_health, "TOR_SOCKS_PROXY", "")
    return tari_health._explorer_tip("https://explorer.example/?json")


def _healthchecks_child(monkeypatch):
    request = {"url": "https://hc.example/uuid", "timeout": 5, "deadline": 5, "proxy": ""}
    monkeypatch.setattr(sys, "stdin", io.StringIO(json.dumps(request)))
    out = io.StringIO()
    monkeypatch.setattr(sys, "stdout", out)
    healthchecks_child.main()
    return json.loads(out.getvalue())["name"]


def _telegram_updates():
    with pytest.raises(Exception, match="refusing unproxied"):
        _bot()._get_updates(0)


CALLERS = {
    "tari_explorer": (_tari, None),
    "xvb_stats": (lambda mp: XvbClient(WALLET, tor_proxy="").get_stats(), None),
    "xvb_rewards": (lambda mp: XvbClient(WALLET, tor_proxy="").get_reward_estimates(), None),
    "xvb_winners": (lambda mp: XvbClient(WALLET, tor_proxy="").get_recent_wins(), None),
    "xvb_register": (lambda mp: XvbClient(WALLET, tor_proxy="").register(), "error"),
    "update_check": (
        lambda mp: GitHubReleaseClient(
            "https://api.example/releases", tor_proxy=""
        ).latest_release(),
        None,
    ),
    "price_feed": (lambda mp: CoinGeckoClient("USD", tor_proxy="").fetch(), None),
    "webhook_sink": (
        lambda mp: WebhookSink("https://hook.example/x", tor_proxy="").send("x"),
        False,
    ),
    "ntfy_sink": (lambda mp: NtfySink("https://ntfy.example/t", tor_proxy="").send("x"), False),
    "telegram_notifier": (
        lambda mp: TelegramNotifier(enabled=True, bot_token="tok", chat_id="1", tor_proxy="").send(
            "x"
        ),
        False,
    ),
    "telegram_reply": (lambda mp: _bot()._send("x"), None),
    "healthchecks_child": (_healthchecks_child, "NoUsableProxy"),
}


@pytest.mark.parametrize("name", sorted(CALLERS))
def test_cleared_proxy_opens_no_socket_and_keeps_the_failure_contract(name, monkeypatch, sockets):
    call, expected = CALLERS[name]
    assert call(monkeypatch) == expected
    assert sockets == []


def test_telegram_get_updates_refuses_before_any_socket(sockets):
    _telegram_updates()
    assert sockets == []
