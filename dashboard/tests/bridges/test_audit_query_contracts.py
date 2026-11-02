from types import SimpleNamespace

import pytest

from mining_dashboard import go_audit_query as bridge
from mining_dashboard.service import audit_service


@pytest.fixture
def query(monkeypatch):
    monkeypatch.setattr(bridge, "PROVIDERS", {"epoch": audit_service._entry_epoch})
    monkeypatch.setattr(bridge, "REFERENCE_FUNCTIONS", {})
    monkeypatch.setattr(bridge, "_value", lambda result, _identities: result)
    return bridge


def test_audit_filter_uses_one_captured_projection_and_original_rows(query, monkeypatch):
    row = {"ts": 2, "value": "Match"}
    calls = []

    def select(operation, **values):
        calls.append((operation, values))
        row["value"] = "late"
        return [0], {}

    monkeypatch.setattr(query, "_call", select)
    assert query.filter_log_entries([row], 0, 3, "MA")[0] is row
    assert calls == [
        (
            "audit-filter",
            {
                "config": {
                    "epochs": [2.0],
                    "fields": [["2", "match"]],
                    "query": "ma",
                    "from": 0,
                    "to": 3,
                }
            },
        )
    ]


def test_audit_filter_reference_path_handles_all_window_and_query_boundaries(query):
    rows = [
        {"ts": None, "value": "match"},
        {"ts": 0, "value": "match"},
        {"ts": 1, "value": "match"},
        {"ts": 2, "value": "miss"},
        {"ts": 3, "value": "match"},
    ]
    assert query.filter_log_entries(iter(rows), 1, 3, "MATCH") == [rows[2]]
    assert query._filter_compat(rows, None, None, None) == rows


@pytest.mark.parametrize("indices", [None, [True], [2], [0, 0], [1, 0]])
def test_audit_filter_rejects_invalid_or_reordered_indices(query, monkeypatch, indices):
    monkeypatch.setattr(query, "_result", lambda *_args, **_values: indices)
    with pytest.raises(RuntimeError, match="invalid selection"):
        query._indices("filter", 2)
    if indices == [1, 0]:
        assert query._indices("merge", 2) == [1, 0]


def test_audit_merge_captures_database_ids_before_live_callback(query, monkeypatch):
    database = {"id": "database", "ts": "2"}
    live = {"id": "live", "ts": "1"}
    calls = []

    def read():
        database["id"] = "late"
        return [live]

    monkeypatch.setattr(audit_service, "recent_changes", read)
    monkeypatch.setattr(
        query,
        "_call",
        lambda operation, **values: (calls.append((operation, values)) or [1, 0], {}),
    )
    result = query._merged_audit_entries(SimpleNamespace(get_audit_events=lambda: [database]))
    assert result == [{**live, "source": "control"}, database]
    assert result[1] is database and "source" not in live
    assert calls[0][1]["config"]["rows"][0]["id"] == "database"


def test_audit_merge_compatibility_deduplicates_and_retains_control_rows(query, monkeypatch):
    database = [{"id": "same", "ts": "2"}]
    control = [{"id": "same", "ts": "3"}, {"id": "new", "ts": "1"}, {"id": "", "ts": "0"}]
    assert query._merge_compat(database, lambda: control) == [
        database[0],
        {**control[1], "source": "control"},
        {**control[2], "source": "control"},
    ]
    monkeypatch.setattr(audit_service, "recent_changes", lambda: control)
    assert query._merged_audit_entries(
        SimpleNamespace(get_audit_events=lambda: iter(database))
    ) == query._merge_compat(database, lambda: control)


@pytest.mark.parametrize(
    "result",
    [
        None,
        [],
        [1, None, None],
        [float("inf"), None, None],
        [None, None, ""],
        [None, None, "x" * 201],
    ],
)
def test_audit_query_rejects_invalid_native_filters(query, monkeypatch, result):
    monkeypatch.setattr(query, "_call", lambda *_args, **_values: (result, {}))
    with pytest.raises(RuntimeError, match="invalid filters"):
        query._log_filters(SimpleNamespace(query={}))


def test_audit_query_normalizes_input_before_policy_and_checks_decoder(query, monkeypatch):
    calls = []
    monkeypatch.setattr(
        query,
        "_call",
        lambda operation, **values: (calls.append((operation, values)) or [2.0, None, "match"], {}),
    )
    assert query._log_filters(
        SimpleNamespace(query={"from": "2", "to": "bad", "q": " match "})
    ) == (2.0, None, "match")
    assert calls == [("audit-query", {"config": {"from": 2.0, "to": None, "query": "match"}})]

    def fail(*_args):
        raise ValueError("bad reference")

    monkeypatch.setattr(query, "_value", fail)
    with pytest.raises(RuntimeError, match="invalid data"):
        query._result("query")


def test_audit_query_install_keeps_all_reference_aliases(query, monkeypatch):
    from mining_dashboard.web import server

    sources = (
        (audit_service, "filter_log_entries"),
        (server, "_merged_audit_entries"),
        (server, "_log_filters"),
    )
    for owner, name in sources:
        monkeypatch.setattr(owner, name, getattr(owner, name))
    query.install()
    assert all(getattr(owner, name) is getattr(query, name) for owner, name in sources)
    assert set(query.REFERENCE_FUNCTIONS) == {
        "filter_log_entries",
        "_merged_audit_entries",
        "_log_filters",
    }
