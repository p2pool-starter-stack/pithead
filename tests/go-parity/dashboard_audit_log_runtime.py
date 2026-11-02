import os
from types import SimpleNamespace

import dashboard_audit_log_plugin as adapter
import pytest

from mining_dashboard import go_editor, go_polling
from mining_dashboard.service import audit_service, data_audit

# ruff: noqa: S101

pytest_plugins = ["dashboard_audit_log_plugin"]
pytestmark = [
    pytest.mark.asyncio,
    pytest.mark.skipif(os.environ.get("PITHEAD_IMPL") != "go", reason="Go dashboard parity only"),
]


def _entry(identifier, status="applied", actor="admin"):
    return {
        "ts": "2026-07-10T12:00:00Z",
        "id": identifier,
        "actor": actor,
        "action": "commit",
        "status": status,
        "keys": "XVB_ENABLED",
    }


def _service(writer):
    return SimpleNamespace(state_manager=SimpleNamespace(add_audit_event=writer))


def _typed_rows(rows):
    return [
        "list",
        [["dict", [[key, ["str", value]] for key, value in row.items()]] for row in rows],
    ]


@pytest.mark.parametrize("foreign", [False, True])
async def test_install_refreshes_only_the_captured_reference_audit_provider(monkeypatch, foreign):
    original = go_polling.REFERENCE_FUNCTIONS["recent_changes"]

    def replacement():
        return []

    provider = replacement if foreign else original
    monkeypatch.setitem(go_editor.PROVIDERS, "audit_provider", provider)
    go_polling.install()
    expected = replacement if foreign else go_polling.recent_audit_changes
    assert go_editor.PROVIDERS["audit_provider"] is expected
    assert audit_service.recent_changes is go_polling.recent_audit_changes


async def test_disabled_mirror_does_not_read_or_call_native(monkeypatch):
    calls = []
    monkeypatch.setattr(data_audit.config, "DASHBOARD_CONTROL_ENABLED", False)
    monkeypatch.setattr(
        audit_service,
        "_tail_json_lines",
        lambda _path: (_ for _ in ()).throw(AssertionError("log read while disabled")),
    )
    monkeypatch.setattr(
        go_polling.go_channel,
        "call",
        lambda helper, payload: calls.append((helper, payload)),
    )
    await data_audit.DataAuditMixin._mirror_control_audit(
        _service(lambda **_kwargs: (_ for _ in ()).throw(AssertionError("write while disabled")))
    )
    assert calls == []


async def test_normal_mirror_reads_once_batches_each_policy_and_writes_sequentially(monkeypatch):
    reads = []
    native_calls = []
    writes = []
    raw = [_entry("old", "previewed"), _entry("new", "applied")]
    call = go_polling.go_channel.call

    def read(path):
        reads.append(path)
        return raw

    def counted(helper, payload):
        native_calls.append((helper, payload["operation"]))
        return call(helper, payload)

    def write(**row):
        writes.append(row)

    monkeypatch.setattr(data_audit.config, "DASHBOARD_CONTROL_ENABLED", True)
    monkeypatch.setattr(audit_service, "_tail_json_lines", read)
    monkeypatch.setattr(go_polling.go_channel, "call", counted)

    await data_audit.DataAuditMixin._mirror_control_audit(_service(write))

    assert len(reads) == 1
    assert native_calls == [
        ("wizard-config", "audit-recent"),
        ("wizard-config", "audit-mirror"),
    ]
    assert [row["id"] for row in writes] == ["old", "new"]


async def test_writer_failure_stops_at_original_prefix(monkeypatch):
    raw = [_entry("first"), _entry("second"), _entry("third")]
    writes = []

    def write(**row):
        writes.append(row["id"])
        if row["id"] == "second":
            raise RuntimeError("write failed")

    monkeypatch.setattr(data_audit.config, "DASHBOARD_CONTROL_ENABLED", True)
    monkeypatch.setattr(audit_service, "_tail_json_lines", lambda _path: raw)
    with pytest.raises(RuntimeError, match="write failed"):
        await data_audit.DataAuditMixin._mirror_control_audit(_service(write))
    assert writes == ["first", "second"]


async def test_replaced_reader_compatibility_stays_lazy_across_writes(monkeypatch):
    entries = [_entry("new", actor="before"), _entry("old", actor="old")]
    writes = []

    def reader():
        return entries

    def write(**row):
        writes.append(row)
        if row["id"] == "old":
            entries[0]["actor"] = "after"

    monkeypatch.setattr(data_audit.config, "DASHBOARD_CONTROL_ENABLED", True)
    monkeypatch.setattr(audit_service, "recent_changes", reader)

    await data_audit.DataAuditMixin._mirror_control_audit(_service(write))

    assert [(row["id"], row["actor"]) for row in writes] == [
        ("old", "old"),
        ("new", "after"),
    ]
    assert adapter.COMPATIBILITY["replaced-reader"] >= 1


@pytest.mark.parametrize(
    ("operation", "reply"),
    [
        ("audit-recent", None),
        (
            "audit-recent",
            _typed_rows(
                [
                    {
                        "id": "id",
                        "ts": "ts",
                        "actor": "actor",
                        "action": "action",
                        "status": "status",
                        "keys": "keys",
                    }
                ]
            ),
        ),
        (
            "audit-recent",
            [
                "list",
                [
                    [
                        "dict",
                        [
                            ["ts", ["int", "1"]],
                            *[
                                [field, ["str", field]]
                                for field in ("id", "actor", "action", "status", "keys")
                            ],
                        ],
                    ]
                ],
            ],
        ),
        (
            "audit-mirror",
            _typed_rows(
                [
                    {
                        "id": "id",
                        "ts": "ts",
                        "source": "other",
                        "actor": "actor",
                        "action": "action",
                        "status": "status",
                        "keys": "keys",
                    }
                ]
            ),
        ),
        (
            "audit-mirror",
            _typed_rows(
                [
                    {
                        "id": "",
                        "ts": "ts",
                        "source": "control",
                        "actor": "actor",
                        "action": "action",
                        "status": "status",
                        "keys": "keys",
                    }
                ]
            ),
        ),
        (
            "audit-mirror",
            _typed_rows(
                [
                    {
                        "id": identifier,
                        "ts": "ts",
                        "source": "control",
                        "actor": "actor",
                        "action": "action",
                        "status": "status",
                        "keys": "keys",
                    }
                    for identifier in ("one", "two")
                ]
            ),
        ),
    ],
)
async def test_native_rejects_malformed_typed_log_replies(monkeypatch, operation, reply):
    call = go_polling.go_channel.call

    def malformed(helper, payload):
        if helper == "wizard-config" and payload.get("operation") == operation:
            return reply
        return call(helper, payload)

    monkeypatch.setattr(go_polling.go_channel, "call", malformed)
    if operation == "audit-recent":
        monkeypatch.setattr(audit_service, "_tail_json_lines", lambda _path: [_entry("id")])
        function = audit_service.recent_changes
    else:

        def function():
            return list(data_audit._control_audit_rows([_entry("id")]))

    with pytest.raises(RuntimeError):
        function()


@pytest.mark.parametrize("operation", ["audit-recent", "audit-mirror"])
@pytest.mark.parametrize("failure", ["invalid", "transport"])
async def test_native_failures_do_not_use_reference_policy(monkeypatch, operation, failure):
    raw = [_entry("id")]
    call = go_polling.go_channel.call

    def failed(helper, payload):
        if helper == "wizard-config" and payload.get("operation") == operation:
            if failure == "transport":
                raise RuntimeError("transport failed")
            return None
        return call(helper, payload)

    monkeypatch.setattr(data_audit.config, "DASHBOARD_CONTROL_ENABLED", True)
    monkeypatch.setattr(audit_service, "_tail_json_lines", lambda _path: raw)
    monkeypatch.setattr(go_polling.go_channel, "call", failed)
    with pytest.raises(RuntimeError):
        await data_audit.DataAuditMixin._mirror_control_audit(_service(lambda **_row: None))
