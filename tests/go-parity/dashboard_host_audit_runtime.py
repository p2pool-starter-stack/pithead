import os
from types import SimpleNamespace
from unittest.mock import AsyncMock

import pytest

from mining_dashboard import go_polling
from mining_dashboard.service import data_audit

# ruff: noqa: S101

pytest_plugins = ["dashboard_host_audit_plugin"]
pytestmark = [
    pytest.mark.asyncio,
    pytest.mark.skipif(os.environ.get("PITHEAD_IMPL") != "go", reason="Go dashboard parity only"),
]


def _service(old, checked=100.0):
    return SimpleNamespace(
        _last_host_config=old,
        _last_host_check=checked,
        _record_audit_event=AsyncMock(),
    )


async def test_native_unexplained_rejects_non_string_paths():
    with pytest.raises(TypeError):
        data_audit._unexplained_config_keys([1], [])


@pytest.mark.parametrize(
    ("operation", "reply"),
    [
        ("audit-diff", None),
        ("audit-diff", ["list", [["str", "a"], ["str", "a"]]]),
        ("audit-diff", ["list", [["str", "b"], ["str", "a"]]]),
        ("audit-diff", ["list", [["str", "config_version.x"]]]),
        ("audit-unexplained", ["list", [["str", "other"]]]),
        ("audit-unexplained", ["list", [["str", "b"], ["str", "a"]]]),
    ],
)
async def test_native_rejects_malformed_typed_policy_replies(monkeypatch, operation, reply):
    call = go_polling.go_channel.call

    def malformed(helper, payload):
        if helper == "wizard-config" and payload.get("operation") == operation:
            return reply
        return call(helper, payload)

    monkeypatch.setattr(go_polling.go_channel, "call", malformed)
    function, args = {
        "audit-diff": (data_audit._diff_config_keys, ({"a": 1}, {"a": 2})),
        "audit-unexplained": (data_audit._unexplained_config_keys, (["a", "b"], [])),
    }[operation]
    with pytest.raises(RuntimeError):
        function(*args)


async def test_watch_preserves_provider_and_policy_order_across_interleaving(monkeypatch):
    old = {"a": 1, "b": 1}
    current = {"a": 2, "b": 2}
    service = _service(old)
    events = []
    native_diff = data_audit._diff_config_keys
    native_unexplained = data_audit._unexplained_config_keys

    def read():
        events.append("read")
        return current

    def diff(before, after):
        events.append("diff")
        return native_diff(before, after)

    def recent():
        events.append("recent")
        current["a"] = 3
        return [{"action": "commit", "status": "applied", "ts": "fresh", "keys": "A"}]

    def parse(value):
        events.append(("parse", value))
        return 100.0

    def paths(value):
        events.append(("paths", value))
        return ["a"]

    def unexplained(changed, explained):
        events.append(("unexplained", list(changed), set(explained)))
        return native_unexplained(changed, explained)

    async def record(*args):
        events.append(("record", args))
        current["b"] = 4

    monkeypatch.setattr(data_audit.config, "DASHBOARD_CONTROL_ENABLED", True)
    monkeypatch.setattr(data_audit, "_read_host_config", read)
    monkeypatch.setattr(data_audit, "_diff_config_keys", diff)
    monkeypatch.setattr(data_audit.audit_service, "recent_changes", recent)
    monkeypatch.setattr(data_audit, "_parse_audit_ts", parse)
    monkeypatch.setattr(data_audit, "env_key_config_paths", paths)
    monkeypatch.setattr(data_audit, "_unexplained_config_keys", unexplained)
    monkeypatch.setattr(data_audit.time, "time", lambda: 200.0)
    service._record_audit_event.side_effect = record

    await data_audit.DataAuditMixin._watch_host_config(service)

    assert events == [
        "read",
        "diff",
        "recent",
        ("parse", "fresh"),
        ("paths", "A"),
        ("unexplained", ["a", "b"], {"a"}),
        ("record", ("host-edit", "", "host-edit", "detected", "b")),
    ]
    assert service._last_host_config == {"a": 3, "b": 4}
    assert service._last_host_check == 200.0


async def test_watch_keeps_provider_filter_order_and_one_second_window(monkeypatch):
    service = _service({"a": 1, "b": 1, "c": 1})
    parsed = []
    expanded = []
    records = [
        {"action": "other", "status": "applied", "ts": "ignored-action", "keys": "X"},
        {"action": "commit", "status": "failed", "ts": "ignored-status", "keys": "X"},
        {"action": "commit", "status": "applied", "ts": "edge", "keys": "A"},
        {"action": "commit-confirmed", "status": "applied", "ts": "stale", "keys": "B"},
        {"action": "commit-approved", "status": "applied", "ts": "fresh", "keys": "C"},
        {"action": "commit", "status": "applied", "ts": "bad", "keys": "D"},
    ]
    times = {"edge": 99.0, "stale": 98.999, "fresh": 101.0, "bad": None}

    def parse(value):
        parsed.append(value)
        return times[value]

    def paths(value):
        expanded.append(value)
        return [value.lower()]

    monkeypatch.setattr(data_audit.config, "DASHBOARD_CONTROL_ENABLED", True)
    monkeypatch.setattr(data_audit, "_read_host_config", lambda: {"a": 2, "b": 2, "c": 2})
    monkeypatch.setattr(data_audit.audit_service, "recent_changes", lambda: records)
    monkeypatch.setattr(data_audit, "_parse_audit_ts", parse)
    monkeypatch.setattr(data_audit, "env_key_config_paths", paths)
    monkeypatch.setattr(data_audit.time, "time", lambda: 200.0)

    await data_audit.DataAuditMixin._watch_host_config(service)

    assert parsed == ["edge", "stale", "fresh", "bad"]
    assert expanded == ["A", "C"]
    service._record_audit_event.assert_awaited_once_with(
        "host-edit", "", "host-edit", "detected", "b"
    )
    assert service._last_host_check == 200.0


async def test_failed_audit_write_does_not_advance_baseline(monkeypatch):
    old = {"a": 1}
    current = {"a": 2}
    service = _service(old, checked=100.0)
    service._record_audit_event.side_effect = RuntimeError("write failed")
    monkeypatch.setattr(data_audit.config, "DASHBOARD_CONTROL_ENABLED", True)
    monkeypatch.setattr(data_audit, "_read_host_config", lambda: current)
    monkeypatch.setattr(data_audit.audit_service, "recent_changes", lambda: [])
    monkeypatch.setattr(data_audit.time, "time", lambda: 200.0)

    with pytest.raises(RuntimeError, match="write failed"):
        await data_audit.DataAuditMixin._watch_host_config(service)
    assert service._last_host_config is old
    assert service._last_host_check == 100.0


@pytest.mark.parametrize("operation", ["audit-diff", "audit-unexplained"])
@pytest.mark.parametrize("failure", ["invalid", "transport"])
async def test_native_failure_never_uses_reference_policy(monkeypatch, operation, failure):
    call = go_polling.go_channel.call

    def failed(helper, payload):
        if helper == "wizard-config" and payload.get("operation") == operation:
            if failure == "transport":
                raise RuntimeError("transport failed")
            return ["list", [["int", "1"]]]
        return call(helper, payload)

    monkeypatch.setattr(go_polling.go_channel, "call", failed)
    function, args = {
        "audit-diff": (data_audit._diff_config_keys, ({"a": 1}, {"a": 2})),
        "audit-unexplained": (data_audit._unexplained_config_keys, (["a"], [])),
    }[operation]
    with pytest.raises(RuntimeError):
        function(*args)
