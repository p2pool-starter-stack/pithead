import os
from types import SimpleNamespace

import dashboard_audit_query_plugin as adapter
import pytest

from mining_dashboard import go_audit_query
from mining_dashboard.service import audit_service
from mining_dashboard.web import server

# ruff: noqa: S101

pytest_plugins = ["dashboard_audit_query_plugin"]
pytestmark = pytest.mark.skipif(
    os.environ.get("PITHEAD_IMPL") != "go", reason="Go dashboard parity only"
)


def _manager(rows):
    return SimpleNamespace(get_audit_events=lambda: rows)


def _request(query=None):
    return SimpleNamespace(query=query or {})


def test_filter_uses_one_immutable_native_call(monkeypatch):
    calls = []
    call = go_audit_query._call

    def counted(operation, **values):
        calls.append((operation, values))
        return call(operation, **values)

    monkeypatch.setattr(go_audit_query, "_call", counted)
    rows = [
        {"ts": 1, "value": "miss"},
        {"ts": 2, "value": "MATCH"},
        {"ts": 3, "value": "match"},
    ]
    result = audit_service.filter_log_entries(rows, frm=2, to=4, q="match")
    assert result == rows[1:]
    assert [name for name, _values in calls] == ["audit-filter"]


def test_filter_selection_uses_one_captured_generation(monkeypatch):
    rows = [{"ts": 1, "value": "match"}, {"ts": 2, "value": "miss"}]
    call = go_audit_query._call
    captured = []

    def interleaved(operation, **values):
        captured.append(values["config"])
        rows[0]["value"] = "miss"
        rows[1]["value"] = "match"
        return call(operation, **values)

    monkeypatch.setattr(go_audit_query, "_call", interleaved)
    result = audit_service.filter_log_entries(rows, frm=0, q="match")
    assert result == [rows[0]]
    assert result[0] is rows[0]
    assert captured[0]["epochs"] == [1.0, 2.0]
    assert captured[0]["fields"] == [["1", "match"], ["2", "miss"]]


def test_filter_reads_epochs_in_order_before_native_call(monkeypatch):
    seen = []

    def epoch(value):
        seen.append(value)
        if value == "bad":
            raise RuntimeError("bad timestamp")
        return value

    monkeypatch.setitem(go_audit_query.PROVIDERS, "epoch", epoch)
    monkeypatch.setattr(audit_service, "_entry_epoch", epoch)
    monkeypatch.setattr(
        go_audit_query,
        "_call",
        lambda *_args, **_kwargs: (_ for _ in ()).throw(AssertionError("native called")),
    )
    with pytest.raises(RuntimeError, match="bad timestamp"):
        audit_service.filter_log_entries([{"ts": 1}, {"ts": "bad"}, {"ts": 3}], frm=0)
    assert seen == [1, "bad"]


def test_replaced_epoch_provider_uses_explicit_compatibility(monkeypatch):
    calls = []

    def epoch(value):
        calls.append(value)
        return float(value)

    monkeypatch.setattr(audit_service, "_entry_epoch", epoch)
    result = audit_service.filter_log_entries([{"ts": "2"}], frm=1)
    assert result == [{"ts": "2"}]
    assert calls == ["2"]
    assert adapter.COMPATIBILITY["filter"] >= 1


def test_generator_filter_compatibility_is_lazy_and_keeps_matching_identity(monkeypatch):
    rows = [
        {"ts": "bad", "value": "needle"},
        {"ts": 9, "value": "needle"},
        {"ts": 20, "value": "needle"},
        {"ts": 15, "value": "miss"},
        {"ts": 15, "value": "needle"},
    ]
    yielded = []

    def entries():
        for row in rows:
            yielded.append(row)
            yield row

    monkeypatch.setattr(
        go_audit_query,
        "_call",
        lambda *_args, **_kwargs: (_ for _ in ()).throw(AssertionError("native called")),
    )
    result = audit_service.filter_log_entries(entries(), frm=10, to=20, q="needle")
    assert result == [rows[4]]
    assert result[0] is rows[4]
    assert yielded == rows
    assert adapter.COMPATIBILITY["filter"] >= 1


def test_merge_reads_database_then_live_once(monkeypatch):
    reads = []
    database = [{"id": "db", "ts": "2"}]
    live = [{"id": "live", "ts": "1"}]

    def database_read():
        reads.append("database")
        return database

    def live_read():
        reads.append("live")
        return live

    monkeypatch.setattr(audit_service, "recent_changes", live_read)
    result = server._merged_audit_entries(SimpleNamespace(get_audit_events=database_read))
    assert [row["id"] for row in result] == ["db", "live"]
    assert reads == ["database", "live"]


def test_merge_captures_database_ids_before_live_provider_mutates_rows(monkeypatch):
    database = [{"id": "old", "ts": "2", "source": "database"}]

    def live_read():
        database[0]["id"] = "new"
        database[0]["ts"] = "3"
        return [{"id": "old", "ts": "4", "source": "live"}]

    monkeypatch.setattr(audit_service, "recent_changes", live_read)
    result = server._merged_audit_entries(_manager(database))
    assert result == [{"id": "new", "ts": "3", "source": "database"}]
    assert result[0] is database[0]


def test_late_merge_compatibility_uses_captured_database_ids(monkeypatch):
    database = [{"id": "old", "ts": "3", "source": "database"}]
    duplicate = {"id": "old", "ts": "4", "source": "live"}
    new = {"id": "new", "ts": "2", "source": "live"}
    no_id = {"id": "", "ts": "1", "source": "live"}
    reads = []

    def live_read():
        reads.append("live")
        database[0]["id"] = 99
        return [duplicate, new, no_id]

    monkeypatch.setattr(audit_service, "recent_changes", live_read)
    monkeypatch.setattr(
        go_audit_query,
        "_call",
        lambda *_args, **_kwargs: (_ for _ in ()).throw(AssertionError("native called")),
    )
    result = server._merged_audit_entries(_manager(database))
    assert reads == ["live"]
    assert result[0] is database[0]
    assert result[0] == {"id": 99, "ts": "3", "source": "database"}
    assert result[1] == {"id": "new", "ts": "2", "source": "control"}
    assert result[1] is not new
    assert result[2] == {"id": "", "ts": "1", "source": "control"}
    assert result[2] is not no_id
    assert duplicate not in result
    assert adapter.COMPATIBILITY["merge"] >= 1


def test_invalid_database_fails_before_live_read(monkeypatch):
    monkeypatch.setattr(
        audit_service,
        "recent_changes",
        lambda: (_ for _ in ()).throw(AssertionError("live read")),
    )
    with pytest.raises(AttributeError):
        server._merged_audit_entries(_manager([None]))


def test_log_filter_inputs_are_read_in_reference_order_before_native(monkeypatch):
    reads = []

    class Query:
        def get(self, name):
            reads.append(name)
            if name == "to":
                raise RuntimeError("query failed")
            return {"q": " value ", "from": "1"}.get(name)

    monkeypatch.setattr(
        go_audit_query,
        "_call",
        lambda *_args, **_kwargs: (_ for _ in ()).throw(AssertionError("native called")),
    )
    with pytest.raises(RuntimeError, match="query failed"):
        server._log_filters(SimpleNamespace(query=Query()))
    assert reads == ["q", "from", "to"]


def test_log_filters_degrade_malformed_bounds_and_return_native_tuple():
    result = server._log_filters(_request({"from": "bad", "to": "", "q": " value "}))
    assert result == (None, None, "value")


@pytest.mark.parametrize(
    ("operation", "invoke"),
    [
        (
            "audit-filter",
            lambda: audit_service.filter_log_entries([{"ts": 1, "value": "x"}], frm=0, q="x"),
        ),
        ("audit-merge", lambda: server._merged_audit_entries(_manager([{"id": "x", "ts": "1"}]))),
        ("audit-query", lambda: server._log_filters(_request({"from": "1"}))),
    ],
)
@pytest.mark.parametrize("failure", ["invalid", "transport"])
def test_native_failures_do_not_use_reference_policy(monkeypatch, operation, invoke, failure):
    call = go_audit_query._call

    def failed(name, **values):
        if name == operation:
            if failure == "transport":
                raise RuntimeError("transport failed")
            return None, values
        return call(name, **values)

    monkeypatch.setattr(go_audit_query, "_call", failed)
    monkeypatch.setattr(audit_service, "recent_changes", lambda: [])
    with pytest.raises(RuntimeError):
        invoke()


@pytest.mark.parametrize(
    ("operation", "reply", "invoke"),
    [
        (
            "audit-filter",
            ["list", [["int", "0"], ["int", "0"]]],
            lambda: audit_service.filter_log_entries([{"ts": 1}], frm=0),
        ),
        (
            "audit-filter",
            ["list", [["int", "1"]]],
            lambda: audit_service.filter_log_entries([{"ts": 1}], frm=0),
        ),
        (
            "audit-filter",
            ["list", [["int", "1"], ["int", "0"]]],
            lambda: audit_service.filter_log_entries([{"value": "x"}, {"value": "x"}], q="x"),
        ),
        (
            "audit-merge",
            ["list", [["int", "1"]]],
            lambda: server._merged_audit_entries(_manager([{"id": "x", "ts": "1"}])),
        ),
        (
            "audit-query",
            ["list", [["int", "1"], ["null", None], ["str", "q"]]],
            lambda: server._log_filters(_request({"q": "q"})),
        ),
        (
            "audit-query",
            ["list", [["float", "nan"], ["null", None], ["str", "q"]]],
            lambda: server._log_filters(_request({"q": "q"})),
        ),
        (
            "audit-query",
            ["list", [["null", None], ["null", None], ["str", ""]]],
            lambda: server._log_filters(_request({"q": "q"})),
        ),
    ],
)
def test_native_rejects_malformed_replies(monkeypatch, operation, reply, invoke):
    call = go_audit_query._call

    def malformed(name, **values):
        if name == operation:
            return reply, {}
        return call(name, **values)

    monkeypatch.setattr(go_audit_query, "_call", malformed)
    monkeypatch.setattr(audit_service, "recent_changes", lambda: [])
    with pytest.raises(RuntimeError):
        invoke()


def test_install_keeps_originals_and_is_idempotent():
    originals = dict(go_audit_query.REFERENCE_FUNCTIONS)
    go_audit_query.install()
    assert go_audit_query.REFERENCE_FUNCTIONS == originals
    assert audit_service.filter_log_entries is go_audit_query.filter_log_entries
    assert server._merged_audit_entries is go_audit_query._merged_audit_entries
    assert server._log_filters is go_audit_query._log_filters
