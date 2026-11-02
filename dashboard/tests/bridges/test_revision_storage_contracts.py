from types import SimpleNamespace

import pytest

from mining_dashboard import go_revision_store as bridge
from mining_dashboard import go_storage
from mining_dashboard.service.workers import worker_config_store, worker_revision_store


@pytest.fixture
def session(monkeypatch):
    events = []
    replies = []
    connection = object.__new__(go_storage.GoConnection)

    def request(operation, **payload):
        events.append((operation, payload))
        return {"result": replies.pop(0)}

    connection._request = request
    cursor = go_storage.GoCursor(connection)
    monkeypatch.setattr(bridge, "_STATE", {"next_drift": worker_config_store._next_drift_from})
    monkeypatch.setattr(bridge, "REFERENCE_FUNCTIONS", {})
    monkeypatch.setattr(bridge, "COMPAT_FUNCTIONS", {})
    return connection, cursor, replies, events


def test_prepare_write_prune_and_drift_use_captured_native_results(session):
    connection, cursor, replies, events = session
    replies.extend(
        [
            {"row": ["old", "change", "older"], "next_slot": 2},
            None,
            None,
            {"row": ["new", "older"], "visible": True},
        ]
    )
    revision = "new"
    row, drift = bridge.prepare(cursor, "worker", revision, None, lambda *_args: pytest.fail())
    assert row.keys() == ["revision", "last_change_id", "drift_from"]
    assert row["revision"] == "old" and drift == "older"
    assert bridge.write(connection, "worker", revision, "change", 10.0, drift) is None
    assert bridge.prune(connection, 1.0) is None
    selected = bridge.drift(cursor, "worker", revision)
    assert selected["drift_from"] == "older" and bridge.visible(selected, revision) is True
    assert events == [
        ("worker-revision-prepare", {"args": ["worker", revision, None]}),
        ("worker-revision-write", {"args": ["worker", revision, "change", 10.0, "older"]}),
        ("worker-revision-prune", {"args": [1.0]}),
        ("worker-revision-drift", {"args": ["worker", revision]}),
    ]


def test_absent_rows_and_replaced_drift_provider(session, monkeypatch):
    _connection, cursor, replies, events = session
    replies.extend([{"row": None, "next_slot": None}, {"row": None, "visible": False}])
    assert bridge.prepare(cursor, "worker", "new", None, None) == (None, None)
    assert bridge.visible(bridge.drift(cursor, "worker", "new"), "new") is False
    replies.append({"row": ["old", None, None], "next_slot": 0})
    monkeypatch.setattr(worker_config_store, "_next_drift_from", object())
    captured = []

    def resolve(row, revision, change):
        captured.append((list(row), revision, change))
        return "provider-drift"

    row, drift = bridge.prepare(cursor, "worker", "new", "change", resolve)
    assert row["revision"] == "old" and drift == "provider-drift"
    assert captured == [(["old", None, None], "new", "change")]
    assert len(events) == 3


@pytest.mark.parametrize(
    "result",
    [
        None,
        {},
        {"row": [], "next_slot": None},
        {"row": [1, 2, {}], "next_slot": 0},
        {"row": None, "next_slot": 0},
        {"row": [1, 2, 3], "next_slot": True},
    ],
)
def test_prepare_rejects_malformed_native_results(session, result):
    _connection, cursor, replies, _events = session
    replies.append(result)
    with pytest.raises(RuntimeError, match="invalid revision prepare"):
        bridge.prepare(cursor, "worker", "new", None, None)


@pytest.mark.parametrize(
    "result",
    [
        None,
        {},
        {"row": None, "visible": True},
        {"row": [], "visible": False},
        {"row": [1, {}], "visible": True},
        {"row": None, "visible": 0},
    ],
)
def test_drift_rejects_malformed_native_results(session, result):
    _connection, cursor, replies, _events = session
    replies.append(result)
    with pytest.raises(RuntimeError, match="invalid revision drift"):
        bridge.drift(cursor, "worker", "new")


def test_mutation_acknowledgements_are_strict(session):
    connection, _cursor, replies, _events = session
    replies.extend([{}, []])
    with pytest.raises(RuntimeError, match="invalid revision write"):
        bridge.write(connection, "worker", "new", None, 1, b"legacy")
    with pytest.raises(RuntimeError, match="invalid revision prune"):
        bridge.prune(connection, 1)


def test_noncanonical_inputs_keep_original_callback_identity(session, monkeypatch):
    connection, cursor, replies, events = session
    calls = []
    for name in ("prepare", "write", "prune", "drift", "visible"):
        monkeypatch.setitem(
            bridge.COMPAT_FUNCTIONS, name, lambda *args, name=name: calls.append((name, args))
        )
    resolver = object()
    bridge.prepare(cursor, "\ud800", "new", None, resolver)
    bridge.write(connection, "worker", "new", None, "clock", None)
    bridge.prune(object(), 0)
    bridge.drift(object(), "worker", "new")
    row = object()
    bridge.visible(row, "new")
    assert [name for name, _args in calls] == ["prepare", "write", "prune", "drift", "visible"]
    assert calls[0][1] == (cursor, "\ud800", "new", None, resolver)
    assert calls[-1][1][0] is row and not replies and not events
    assert not bridge._text("")
    assert not bridge._text("x" * 4097)
    assert bridge._scalar(b"data") and not bridge._scalar({})


def test_revision_install_binds_only_the_expected_helpers(monkeypatch):
    from mining_dashboard.service import workers

    def reference(*args, **kwargs):
        return args, kwargs

    reference.marker = "reference"
    fake = SimpleNamespace(
        **{name: reference for name in ("prepare", "write", "prune", "drift", "visible")}
    )
    monkeypatch.setattr(workers, "worker_revision_store", fake)
    monkeypatch.setattr(bridge, "_STATE", {})
    monkeypatch.setattr(bridge, "REFERENCE_FUNCTIONS", {})
    monkeypatch.setattr(bridge, "COMPAT_FUNCTIONS", {})
    bridge.install()
    bridge.install()
    assert bridge._STATE["next_drift"] is worker_config_store._next_drift_from
    for name in bridge.REFERENCE_FUNCTIONS:
        assert getattr(fake, name) is getattr(bridge, name)
        assert bridge.REFERENCE_FUNCTIONS[name] is reference
        assert bridge.COMPAT_FUNCTIONS[name].marker == "reference"
        assert bridge.COMPAT_FUNCTIONS[name]("value", extra=1) == (("value",), {"extra": 1})
    assert worker_revision_store is not fake
