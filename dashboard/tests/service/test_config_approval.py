import asyncio
from types import SimpleNamespace

import pytest

from mining_dashboard.service.notify import telegram_commands


@pytest.mark.asyncio
async def test_configuration_approval_pauses_dashboard_polling_for_host():
    data = SimpleNamespace(latest_data={}, state_manager=object())
    bot = telegram_commands.TelegramCommandBot(
        data,
        enabled=True,
        bot_token="token",
        chat_id="42",
        control_enabled=False,
        allowed_ids=("7",),
        confirm_timeout=60,
    )
    assert await bot.pause_for_host_approval()
    assert bot._config_pause_until > 0


@pytest.mark.asyncio
async def test_configuration_approval_waits_for_an_active_poll():
    data = SimpleNamespace(latest_data={}, state_manager=object())
    bot = telegram_commands.TelegramCommandBot(
        data,
        enabled=True,
        bot_token="token",
        chat_id="42",
        control_enabled=False,
        allowed_ids=("7",),
        long_poll=1,
    )
    bot._poll_idle.clear()
    task = asyncio.create_task(bot.pause_for_host_approval())
    await asyncio.sleep(0)
    assert not task.done()
    bot._poll_idle.set()
    assert await task


def test_dashboard_does_not_consume_configuration_callbacks(monkeypatch):
    data = SimpleNamespace(latest_data={}, state_manager=object())
    bot = telegram_commands.TelegramCommandBot(
        data,
        enabled=True,
        bot_token="token",
        chat_id="42",
        control_enabled=False,
        allowed_ids=("7",),
    )
    seen = {}

    class Response:
        def raise_for_status(self):
            return None

        def json(self):
            return {"ok": True, "result": []}

    monkeypatch.setattr(
        telegram_commands,
        "bounded_get",
        lambda _url, **kwargs: seen.update(kwargs) or Response(),
    )
    bot._get_updates(0)
    assert seen["params"]["allowed_updates"] == '["message"]'
