import json
from types import SimpleNamespace

import pytest

from mining_dashboard import go_wizard_state, go_wizard_typed


def test_state_plan_decodes_each_phase_and_rejects_bad_ack(monkeypatch):
    replies = {
        "prepare": {
            "next": "config",
            "attempt": ["dict", []],
            "changes": ["list", []],
            "remember": True,
            "read_handoff": False,
            "need_defaults": True,
        },
        "config": {
            "next": "response",
            "config": ["dict", []],
            "new_machine": False,
            "mode": "setup",
        },
        "response": {"next": "ready", "body": ["dict", [["ok", ["bool", True]]]]},
    }
    monkeypatch.setattr(
        go_wizard_state.go_channel,
        "call",
        lambda helper, payload: replies[payload["phase"]],
    )
    assert go_wizard_state._plan("prepare")["attempt"] == {}
    assert go_wizard_state._plan("config")["config"] == {}
    assert go_wizard_state._plan("response")["body"] == {"ok": True}

    monkeypatch.setattr(go_wizard_state.go_channel, "call", lambda *args: {"next": "wrong"})
    with pytest.raises(RuntimeError, match="invalid native wizard state phase"):
        go_wizard_state._plan("prepare")


@pytest.mark.parametrize(
    "phase,reply,message",
    [
        (
            "prepare",
            {
                "next": "config",
                "attempt": ["list", []],
                "changes": ["list", []],
                "remember": True,
                "read_handoff": False,
                "need_defaults": True,
            },
            "preparation",
        ),
        (
            "config",
            {
                "next": "response",
                "config": ["dict", []],
                "new_machine": 1,
                "mode": "setup",
            },
            "configuration",
        ),
        ("response", {"next": "ready", "body": ["list", []]}, "response"),
    ],
)
def test_state_plan_validates_phase_shapes(monkeypatch, phase, reply, message):
    monkeypatch.setattr(go_wizard_state.go_channel, "call", lambda *args: reply)
    with pytest.raises(RuntimeError, match=message):
        go_wizard_state._plan(phase)


def test_state_build_preserves_provider_order(monkeypatch):
    from mining_dashboard.wizard import server

    events = []

    def plan(phase, **values):
        events.append(("plan", phase))
        if phase == "prepare":
            return {
                "attempt": {},
                "changes": ["change"],
                "remember": True,
                "read_handoff": True,
                "need_defaults": True,
            }
        if phase == "config":
            return {"config": {"ready": True}, "new_machine": True, "mode": "setup"}
        return {"body": {"stage": values["stage"]}}

    def spool_json(name):
        events.append(("json", name))
        return {"budget": 1} if name == "disk-budget.json" else {}

    def spool_read(name, *args):
        events.append(("read", name))
        if name == "handoff.json":
            return '{"role":"rig"}'
        if name == "platform.txt":
            return "test"
        return ""

    monkeypatch.setattr(go_wizard_state, "_plan", plan)
    monkeypatch.setattr(server, "_authed", lambda request: True)
    monkeypatch.setattr(server, "_reference", lambda: {"old": True})
    monkeypatch.setattr(server, "wizard_stage", lambda: "install")
    monkeypatch.setattr(server, "_last_attempt", lambda: {})
    monkeypatch.setattr(server, "recovery_state", lambda *args: ([], {}, "token"))
    monkeypatch.setattr(server, "remember_changes", lambda *args: events.append(("remember",)))
    monkeypatch.setattr(server, "spool_dir", lambda: "/spool")
    monkeypatch.setattr(server, "_spool_json", spool_json)
    monkeypatch.setattr(server, "_spool_read", spool_read)
    monkeypatch.setattr(server, "_spool_write_text", lambda *args: None)
    monkeypatch.setattr(server, "_disks", lambda: [{"name": "disk"}])
    monkeypatch.setattr(server, "handoff_dir", lambda: "/handoff")
    monkeypatch.setattr(server, "installer_mode", lambda: False)
    monkeypatch.setattr(server, "new_machine_answers", lambda *args: {"answer": True})
    monkeypatch.setattr(server, "_rig_defaults", lambda: {})
    monkeypatch.setattr(server, "_data_wiped", lambda: False)
    monkeypatch.setattr(server, "_saved_role", lambda: "rig")
    monkeypatch.setattr(server, "saved_probe", lambda callback: {})
    request = SimpleNamespace(app={"restore_enabled": True})

    response = go_wizard_state.build(request)

    assert json.loads(response.body) == {"stage": "install"}
    assert response.headers["Cache-Control"] == "no-store"
    assert [item for item in events if item[0] == "plan"] == [
        ("plan", "prepare"),
        ("plan", "config"),
        ("plan", "response"),
    ]


def test_state_build_rejects_unauthenticated(monkeypatch):
    from mining_dashboard.wizard import server

    monkeypatch.setattr(server, "_authed", lambda request: False)
    response = go_wizard_state.build(SimpleNamespace())
    assert response.status == 401


def test_typed_execute_preserves_action_order(monkeypatch):
    from mining_dashboard.wizard import server

    events = []
    monkeypatch.setattr(server, "_spool_write_text", lambda *args: events.append(("text", *args)))
    monkeypatch.setattr(server, "remember_changes", lambda *args: events.append(("remember",)))
    monkeypatch.setattr(server, "spool_dir", lambda: "/spool")
    monkeypatch.setattr(server, "_spool_json", lambda name: {})
    monkeypatch.setattr(
        server, "_spool_write_config", lambda value: events.append(("config", value))
    )
    monkeypatch.setattr(server, "explicit_wizard_config", lambda cfg, ref: {"explicit": cfg})
    monkeypatch.setattr(
        go_wizard_typed, "_basic_actions", lambda result: events.append(("basic", result))
    )
    go_wizard_typed._execute(
        {
            "actions": [
                {"operation": "report"},
                {"operation": "remember"},
                {"operation": "attempt"},
                {"operation": "config"},
                {"operation": "other"},
            ]
        },
        cfg={"a": 1},
        ref={},
        changes=["change"],
        report={"ok": True},
    )
    assert [event[0] for event in events] == ["text", "remember", "text", "config", "basic"]


def test_typed_config_raw_and_form_paths(monkeypatch):
    from mining_dashboard.wizard import server

    rejected = []
    monkeypatch.setattr(server.documents, "loads", lambda raw: {"raw": raw})
    monkeypatch.setattr(server.documents, "reject_placeholders", lambda cfg: rejected.append(cfg))
    assert go_wizard_typed._config({}, '{"a":1}') == {"raw": '{"a":1}'}
    assert rejected

    monkeypatch.setattr(server, "_spool_read", lambda name: "test")
    monkeypatch.setattr(server, "_spool_json", lambda name: {})
    monkeypatch.setattr(server, "_disks", lambda: [])
    monkeypatch.setattr(server, "tari_disk_default", lambda *args: "off")
    monkeypatch.setattr(server, "build_config", lambda *args, **kwargs: {"built": True})
    assert go_wizard_typed._config({}, "") == {"built": True}

    monkeypatch.setattr(server, "build_config", lambda *args, **kwargs: [])
    with pytest.raises(ValueError, match="top level"):
        go_wizard_typed._config({}, "")


async def test_typed_submit_successful_phase_contract(monkeypatch):
    from mining_dashboard import go_wizard_preparation
    from mining_dashboard.wizard import server

    calls = []

    def call(phase, **values):
        calls.append((phase, values))
        replies = {
            "start": {"next": "route"},
            "route": {"next": "config"},
            "prepared": {"next": "install"},
            "install": {"next": "probe", "install": False},
            "report": {"next": "verdict"},
            "verdict": {"next": "accepted"},
            "accepted": {
                "body": {"config_changes": ["list", []]},
                "status": 200,
            },
        }
        return replies[phase]

    form = {"config": "", "disk": "", "wipe": "keep"}
    request = SimpleNamespace(post=lambda: None)

    async def post():
        return form

    request.post = post
    monkeypatch.setattr(go_wizard_typed, "_call", call)
    monkeypatch.setattr(go_wizard_typed, "_execute", lambda *args, **kwargs: None)
    monkeypatch.setattr(go_wizard_typed, "_config", lambda form, raw: {"ready": True})
    monkeypatch.setattr(go_wizard_preparation, "prepare", lambda cfg, ref: (cfg, []))
    monkeypatch.setattr(server, "_reference", lambda: {})
    monkeypatch.setattr(server, "installer_mode", lambda: False)
    monkeypatch.setattr(server, "_disks", lambda: [])
    monkeypatch.setattr(
        server, "probe_remote_nodes", lambda cfg: _async_value({"configured": True, "ok": True})
    )

    response = await go_wizard_typed._submit_locked(request)

    assert response.status == 200
    assert json.loads(response.body) == {"config_changes": []}
    assert [phase for phase, _ in calls] == [
        "start",
        "route",
        "prepared",
        "install",
        "report",
        "verdict",
        "accepted",
    ]


async def _async_value(value):
    return value
