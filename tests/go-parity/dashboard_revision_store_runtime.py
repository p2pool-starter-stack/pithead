import base64
import math

import pytest

from mining_dashboard import go_revision_store, go_storage

# ruff: noqa: S101


def _conn(result):
    conn = object.__new__(go_storage.GoConnection)
    conn._request = lambda operation, **payload: {"result": result(operation, payload)}
    return conn


def _cursor(conn):
    return go_storage.GoCursor(conn)


def test_prepare_reconstructs_row_and_native_drift(monkeypatch):
    values = ["before", "change", "older"]
    conn = _conn(lambda operation, payload: {"row": values, "next_slot": 0})
    called = []
    row, drift = go_revision_store.prepare(
        _cursor(conn), "rig.example.com", "after", "change", lambda *args: called.append(args)
    )
    assert [row["revision"], row["last_change_id"], row["drift_from"]] == values
    assert drift == "before"
    assert called == []


def test_prepare_uses_live_replaced_provider_once(monkeypatch):
    from mining_dashboard.service.workers import worker_config_store

    conn = _conn(lambda operation, payload: {"row": ["a", None, None], "next_slot": 0})
    calls = []
    monkeypatch.setattr(worker_config_store, "_next_drift_from", lambda *args: None)
    result = go_revision_store.prepare(
        _cursor(conn), "rig.example.com", "b", None, lambda *args: calls.append(args) or "custom"
    )
    assert result[1] == "custom"
    assert len(calls) == 1


def test_prepare_decodes_blob_and_preserves_large_legacy_drift():
    large = "x" * 5000
    encoded = {"$bytes": base64.b64encode(b"legacy").decode()}
    conn = _conn(lambda operation, payload: {"row": [encoded, None, large], "next_slot": 2})
    row, drift = go_revision_store.prepare(
        _cursor(conn), "rig.example.com", "revision", None, lambda *args: None
    )
    assert row["revision"] == b"legacy"
    assert drift is large


@pytest.mark.parametrize("operation", ["worker-revision-write", "worker-revision-prune"])
def test_nil_mutations_are_strict(operation):
    conn = _conn(lambda actual, payload: {} if actual == operation else None)
    with pytest.raises(RuntimeError, match="invalid revision"):
        if operation.endswith("write"):
            go_revision_store.write(conn, "rig.example.com", "r", None, math.nan, None)
        else:
            go_revision_store.prune(conn, math.inf)


@pytest.mark.parametrize(
    "result",
    [None, {}, {"row": [], "visible": False}, {"row": ["a", None], "visible": 1}],
)
def test_drift_rejects_malformed_results(result):
    conn = _conn(lambda operation, payload: result)
    with pytest.raises(RuntimeError, match="invalid revision drift"):
        go_revision_store.drift(_cursor(conn), "rig.example.com", "revision")


def test_drift_plan_preserves_original_values():
    conn = _conn(lambda operation, payload: {"row": ["stored", b"before"], "visible": True})
    revision = "current"
    row = go_revision_store.drift(_cursor(conn), "rig.example.com", revision)
    assert go_revision_store.visible(row, revision) is True
    assert row["drift_from"] == b"before"


def test_absent_drift_consumes_native_false_without_reference(monkeypatch):
    def fail(*args):
        raise AssertionError(args)

    monkeypatch.setattr(go_revision_store, "_compat", fail)
    conn = _conn(lambda operation, payload: {"row": None, "visible": False})
    revision = "current"
    row = go_revision_store.drift(_cursor(conn), "rig.example.com", revision)
    assert go_revision_store.visible(row, revision) is False


def test_reference_visibility_uses_inequality_and_truthiness():
    calls = []

    class Drift:
        def __bool__(self):
            calls.append("bool")
            return True

    class Revision:
        def __ne__(self, other):
            calls.append(("ne", other))
            return False

        def __eq__(self, other):
            raise AssertionError(other)

    row = {"drift_from": Drift(), "revision": Revision()}
    assert go_revision_store.COMPAT_FUNCTIONS["visible"](row, "current") is True
    assert calls == ["bool", ("ne", "current")]


def test_custom_connection_uses_reference_helper():
    class Connection:
        def execute(self, *args):
            del args
            raise LookupError("reference")

    with pytest.raises(LookupError, match="reference"):
        go_revision_store.drift(Connection(), "rig.example.com", "revision")
