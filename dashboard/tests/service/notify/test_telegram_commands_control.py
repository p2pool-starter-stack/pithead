# ruff: noqa: F403, F405
from tests.service.notify._telegram_commands_support import *  # noqa: F403


def test_control_disabled_without_allow_list(monkeypatch):
    # control_enabled collapses to False when nobody is allow-listed, even with the flag on.
    bot = _control_bot(monkeypatch, allowed=())
    assert bot.control_enabled is False


def test_reply_for_never_handles_control_verbs(monkeypatch):
    # reply_for stays pure/read-only: a control verb returns None there (it is routed elsewhere).
    bot = _control_bot(monkeypatch, allowed=("7",))
    assert bot.reply_for("/restart") is None and bot.reply_for("/apply") is None


def test_help_lists_control_commands_only_when_enabled(monkeypatch):
    on = _control_bot(monkeypatch, allowed=("7",))
    off = _bot(monkeypatch)
    assert "/restart" in on.reply_for("/help")
    assert "/restart" not in off.reply_for("/help")


def test_control_parses_only_bounded_verbs():
    # The bounded action set: restart/apply are recognised, anything else is "unknown".
    assert tc.parse_command("/restart") == "restart"
    assert tc.parse_command("/apply") == "apply"
    assert tc.parse_command("/reboot") == "unknown"
    assert tc.parse_command("/rm -rf") == "unknown"


async def test_control_command_from_non_allowlisted_id_is_refused(monkeypatch):
    # A /restart from the right chat but a NON-allow-listed user id must not send a confirm and must
    # never reach the spool — silent refusal, logged host-side/dashboard-side.
    bot = _control_bot(monkeypatch, allowed=("7",))
    prompts, submits = [], []
    monkeypatch.setattr(bot, "_send_confirm", lambda verb, token: prompts.append(verb))
    monkeypatch.setattr(tc.control_service, "submit", lambda *a, **k: submits.append(a))
    await bot._handle_update(
        {"message": {"chat": {"id": 42}, "from": {"id": 999}, "text": "/restart"}}
    )
    assert prompts == [] and submits == []


async def test_control_command_when_disabled_behaves_as_unknown(monkeypatch):
    bot = _bot(monkeypatch)  # read-only bot, control off
    sent = []
    monkeypatch.setattr(bot, "_send", sent.append)
    await bot._handle_update(
        {"message": {"chat": {"id": 42}, "from": {"id": 7}, "text": "/restart"}}
    )
    assert len(sent) == 1 and "Unknown command" in sent[0]


async def test_control_allowlisted_id_gets_confirm_prompt(monkeypatch):
    bot = _control_bot(monkeypatch, allowed=("7",))
    tx = _Transport().install(monkeypatch)
    await bot._handle_update(
        {"message": {"chat": {"id": 42}, "from": {"id": 7}, "text": "/restart"}}
    )
    # The prompt names the concrete action and carries a single inline confirm button (#338).
    assert tx.token and any("Confirm /restart" in t for t in tx.texts())


async def test_confirm_dispatches_intent_to_spool(monkeypatch):
    bot = _control_bot(monkeypatch, allowed=("7",))
    tx = _Transport().install(monkeypatch)
    submits = []
    monkeypatch.setattr(
        tc.control_service,
        "submit",
        lambda action, cfg, actor: submits.append((action, cfg, actor)) or "rid",
    )
    # 1) operator issues /apply → prompt (real _send_confirm), 2) taps the button → real dispatch.
    await bot._handle_update({"message": {"chat": {"id": 42}, "from": {"id": 7}, "text": "/apply"}})
    await bot._handle_update(
        {
            "callback_query": {
                "id": "cb1",
                "from": {"id": 7},
                "message": {"chat": {"id": 42}},
                "data": f"confirm:{tx.token}",
            }
        }
    )
    # Intent rode the #33 spool: fixed verb, no config, actor = tg-<uid>. Bot acked in-chat.
    assert submits == [("apply", None, "tg-7")]
    assert any("Apply confirmed" in t for t in tx.texts())


async def test_dispatch_reports_spool_write_failure(monkeypatch):
    bot = _control_bot(monkeypatch, allowed=("7",))
    tx = _Transport().install(monkeypatch)

    def boom(*a, **k):
        raise OSError("spool full")

    monkeypatch.setattr(tc.control_service, "submit", boom)
    await bot._handle_update(
        {"message": {"chat": {"id": 42}, "from": {"id": 7}, "text": "/restart"}}
    )
    await bot._handle_update(
        {
            "callback_query": {
                "id": "cb1",
                "from": {"id": 7},
                "message": {"chat": {"id": 42}},
                "data": f"confirm:{tx.token}",
            }
        }
    )
    assert any("Could not queue" in t for t in tx.texts())


async def test_confirm_from_foreign_user_is_denied(monkeypatch):
    bot = _control_bot(monkeypatch, allowed=("7",))
    tx = _Transport().install(monkeypatch)
    submits = []
    monkeypatch.setattr(tc.control_service, "submit", lambda *a, **k: submits.append(a))
    await bot._handle_update(
        {"message": {"chat": {"id": 42}, "from": {"id": 7}, "text": "/restart"}}
    )
    # A DIFFERENT user id taps the button — denied, nothing spooled.
    await bot._handle_update(
        {
            "callback_query": {
                "id": "cb1",
                "from": {"id": 999},
                "message": {"chat": {"id": 42}},
                "data": f"confirm:{tx.token}",
            }
        }
    )
    assert submits == [] and any("denied" in t.lower() for t in tx.texts())


async def test_confirm_after_timeout_is_denied(monkeypatch):
    # End-to-end deny-on-timeout through the bot: a button tapped after the window denies, no spool.
    bot = _control_bot(monkeypatch, allowed=("7",))
    bot._gate = tc.ControlGate(timeout_s=0)  # any later tap is already past the deadline
    tx = _Transport().install(monkeypatch)
    submits = []
    monkeypatch.setattr(tc.control_service, "submit", lambda *a, **k: submits.append(a))
    await bot._handle_update(
        {"message": {"chat": {"id": 42}, "from": {"id": 7}, "text": "/restart"}}
    )
    await bot._handle_update(
        {
            "callback_query": {
                "id": "cb1",
                "from": {"id": 7},
                "message": {"chat": {"id": 42}},
                "data": f"confirm:{tx.token}",
            }
        }
    )
    assert submits == [] and any("denied" in t.lower() for t in tx.texts())


async def test_rate_limited_prompt_tells_the_operator(monkeypatch):
    bot = _control_bot(monkeypatch, allowed=("7",))
    bot._gate = tc.ControlGate(timeout_s=60, max_prompts_per_hour=1)
    tx = _Transport().install(monkeypatch)
    for _ in range(2):
        await bot._handle_update(
            {"message": {"chat": {"id": 42}, "from": {"id": 7}, "text": "/restart"}}
        )
    assert any("Too many confirmation prompts" in t for t in tx.texts())


def test_allowed_updates_requests_callbacks_only_when_control_on(monkeypatch):
    on = _control_bot(monkeypatch, allowed=("7",))
    off = _bot(monkeypatch)
    seen = {}

    def fake_get(url, params=None, **kw):
        seen["allowed"] = params["allowed_updates"]
        return _Resp({"ok": True, "result": []})

    monkeypatch.setattr(tc, "bounded_get", fake_get)
    on._get_updates(0)
    assert "callback_query" in seen["allowed"]
    off._get_updates(0)
    assert "callback_query" not in seen["allowed"]
