# ruff: noqa: F403, F405
"""The bot has NO write surface (#2076).

These are regression guards, not feature tests: #338's ``/restart`` / ``/apply`` verbs and #911's
config-approval tap were removed, and each assertion below fails if any part of either comes back.
They assert against the SHIPPED class, so a re-introduced attribute or code path reddens them even
if it is wired somewhere this file never names.
"""

from tests.service.notify._telegram_commands_support import *  # noqa: F403


def test_no_control_verbs_are_recognised():
    # The two removed verbs must parse as "unknown" — the same as any other unknown slash command,
    # so the bot cannot even SELECT a host action. Asserted against parse_command itself, which is
    # the only place a command word is resolved.
    assert tc.parse_command("/restart") == "unknown"
    assert tc.parse_command("/apply") == "unknown"
    # Control over the control: a surviving read-only verb still parses, so a blanket "everything
    # is unknown" regression could not produce this pair of results.
    assert tc.parse_command("/status") == "status"


def test_no_control_symbols_survive_in_the_module():
    # The module-level tables and the five handler methods are gone. Named individually so the
    # failure message says WHICH one came back.
    for name in ("CONTROL_COMMANDS", "CONTROL_HELP_TEXT", "ControlGate", "control_service"):
        assert not hasattr(tc, name), f"{name} is back in telegram_commands"
    bot_attrs = dir(tc.TelegramCommandBot)
    for name in (
        "_handle_control",
        "_handle_callback",
        "_dispatch_control",
        "_send_confirm",
        "_answer_callback",
        "pause_for_host_approval",
        "config_approval_enabled",
        "control_enabled",
    ):
        assert name not in bot_attrs, f"TelegramCommandBot.{name} is back"
    # config_approval.ControlGate is gone as a MODULE, not merely unimported here.
    with pytest.raises(ImportError):
        __import__("mining_dashboard.service.config_approval")


def test_the_constructor_rejects_every_removed_control_kwarg():
    """The discriminating half of the transport guards below.

    ``_get_updates`` and ``_help_text`` used to branch on ``control_enabled``; with a DISABLED bot
    both branches produce the read-only answer, so asserting the answer alone would pass against
    the old code too. What cannot pass against it is the constructor refusing the kwargs that fed
    those branches — there is no longer a way to build a bot in the control-enabled state.
    """
    ds = SimpleNamespace(latest_data={}, state_manager=object())
    for kwarg in ("control_enabled", "allowed_ids", "confirm_timeout"):
        with pytest.raises(TypeError):
            tc.TelegramCommandBot(ds, bot_token="tok", chat_id="42", **{kwarg: True})
    # Control: the surviving kwargs still construct, so the TypeErrors above are about the REMOVED
    # names and not about a constructor that rejects everything.
    assert tc.TelegramCommandBot(ds, enabled=True, bot_token="tok", chat_id="42").enabled is True


def test_help_never_advertises_a_control_command(monkeypatch):
    # Shipped-behaviour assertion, not a discriminating guard: the old code produced this same
    # body for a control-DISABLED bot. The guard that a control-enabled bot can no longer exist is
    # test_the_constructor_rejects_every_removed_control_kwarg.
    body = _bot(monkeypatch).reply_for("/help")
    assert "/restart" not in body and "/apply" not in body
    assert "/status" in body  # the read-only set is still advertised


def test_removed_verbs_answer_with_the_unknown_command_help(monkeypatch):
    # Not silence: a removed verb must behave like any unknown command so an operator who still
    # types /restart is told what the bot does understand.
    bot = _bot(monkeypatch)
    reply = bot.reply_for("/restart")
    assert "Unknown command." in reply and "/status" in reply


def test_get_updates_never_subscribes_to_callback_queries(monkeypatch):
    # allowed_updates is the transport-level guarantee: Telegram is never asked for the button
    # taps the removed flow relied on. Captured off the real _get_updates call, not a constant.
    # Also a shipped-behaviour assertion: the old code emitted this for a control-DISABLED bot
    # too, and the constructor test above is what makes the enabled variant unreachable.
    seen = {}

    def fake_get(url, params=None, **kw):
        seen.update(params or {})
        return _Resp({"ok": True, "result": []})

    monkeypatch.setattr(tc, "bounded_get", fake_get)
    _make_bot()._get_updates(0)
    assert seen["allowed_updates"] == '["message"]'
    assert "callback_query" not in seen["allowed_updates"]


async def test_a_callback_query_update_is_ignored_and_answers_nothing(monkeypatch):
    # Even if Telegram delivers one (a tap on a button from BEFORE the upgrade, still in the
    # backlog), the bot must not act on it and must not reply. _Transport records every POST, so a
    # revived answerCallbackQuery or dispatch would show up here.
    bot = _bot(monkeypatch)
    tx = _Transport().install(monkeypatch)
    await bot._handle_update(
        {
            "callback_query": {
                "id": "cb1",
                "from": {"id": 7},
                "data": "confirm:deadbeef",
                "message": {"chat": {"id": 42}, "message_id": 5, "text": "Confirm /restart?"},
            }
        }
    )
    assert tx.posts == []


async def test_a_plain_status_message_still_answers(monkeypatch):
    # The firing control for the two tests above: the same _handle_update path DOES reply to a
    # normal message, so "no posts" is proof of ignoring the callback, not of a dead transport.
    bot = _bot(monkeypatch)
    tx = _Transport().install(monkeypatch)
    await bot._handle_update({"message": {"chat": {"id": 42}, "text": "/status"}})
    assert len(tx.posts) == 1 and "Hashrate" in tx.texts()[0]
