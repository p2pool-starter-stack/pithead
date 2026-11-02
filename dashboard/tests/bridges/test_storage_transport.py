import io
import json
import math
import sqlite3
import subprocess
from types import SimpleNamespace

import pytest

from mining_dashboard import go_storage


class Process:
    def __init__(self, replies):
        self.stdin = io.StringIO()
        self.stdout = io.StringIO("".join(replies))
        self.code = None
        self.events = []

    def poll(self):
        return self.code

    def terminate(self):
        self.events.append("terminate")
        self.code = 0

    def kill(self):
        self.events.append("kill")
        self.code = 0

    def wait(self, timeout):
        self.events.append(("wait", timeout))
        return self.code


def reply(**values):
    return json.dumps({"ok": True, **values}) + "\n"


@pytest.fixture
def connection_factory(monkeypatch):
    active = []

    def create(replies, owner=None):
        process = Process(replies)
        monkeypatch.setattr(go_storage.subprocess, "Popen", lambda *_args, **_kwargs: process)
        connection = go_storage.GoConnection("contract.db", owner)
        active.append(connection)
        return connection, process

    yield create
    for connection in active:
        connection._closed = True
        connection._finalizer()


def test_storage_binary_and_scalar_wire_contract(monkeypatch):
    monkeypatch.delenv("PITHEAD_DASHBOARD_GO_BINARY", raising=False)
    assert go_storage._binary().endswith("/go/bin/dashboard")
    monkeypatch.setenv("PITHEAD_DASHBOARD_GO_BINARY", "native-storage")
    assert go_storage._binary() == "native-storage"
    wire = go_storage._encode({"rows": (b"\x00\xff", math.nan, math.inf, -math.inf, "plain")})
    assert wire == {
        "rows": [
            {"$bytes": "AP8="},
            {"$float": "nan"},
            {"$float": "inf"},
            {"$float": "-inf"},
            "plain",
        ]
    }
    values = go_storage._decode(wire)["rows"]
    assert values[0] == b"\x00\xff" and math.isnan(values[1])
    assert values[2:] == [math.inf, -math.inf, "plain"]
    go_storage._check_text(["valid", ("nested", 1)])
    with pytest.raises(UnicodeEncodeError):
        go_storage._check_text(["\ud800"])


@pytest.mark.parametrize(
    ("kind", "expected"),
    [
        ("corrupt", sqlite3.DatabaseError),
        ("corruption", sqlite3.DatabaseError),
        ("database", sqlite3.DatabaseError),
        ("DatabaseError", sqlite3.DatabaseError),
        ("IntegrityError", sqlite3.IntegrityError),
        ("ProgrammingError", sqlite3.ProgrammingError),
        ("OverflowError", OverflowError),
        ("other", sqlite3.OperationalError),
    ],
)
def test_storage_error_classification(kind, expected):
    error = go_storage._error({"error_kind": kind, "error": "failure"})
    assert type(error) is expected
    assert str(error) == "failure"
    assert "helper failed" in str(go_storage._error({}))


def test_connection_and_cursor_protocol(connection_factory):
    rows = {"columns": ["id", "value"], "rows": [[1, {"$bytes": "AP8="}], [2, "second"]]}
    connection, process = connection_factory(
        [
            reply(),
            reply(result=rows),
            reply(result={"rowcount": 2, "lastrowid": 7}),
            reply(),
            reply(),
            reply(),
        ]
    )
    cursor = connection.execute("select id,value", ("bound",))
    assert cursor.description == [
        ("id", None, None, None, None, None, None),
        ("value", None, None, None, None, None, None),
    ]
    first = cursor.fetchone()
    assert first.keys() == ["id", "value"]
    assert len(first) == 2 and list(first) == [1, b"\x00\xff"]
    assert first["id"] == first[0] == 1
    assert next(cursor)["value"] == "second"
    assert cursor.fetchall() == [] and cursor.fetchone() is None
    with pytest.raises(StopIteration):
        next(cursor)
    cursor = connection.executemany("insert into sample values(?)", ((1,), (2,)))
    assert cursor.rowcount == 2 and cursor.lastrowid == 7 and cursor.description is None
    cursor.close()
    assert cursor.fetchall() == []
    with connection as entered:
        assert entered is connection
    assert connection.__exit__(ValueError, ValueError(), None) is False
    frames = [json.loads(line) for line in process.stdin.getvalue().splitlines()]
    assert frames == [
        {"op": "open", "path": "contract.db"},
        {"op": "execute", "sql": "select id,value", "args": ["bound"]},
        {"op": "executemany", "sql": "insert into sample values(?)", "args_list": [[1], [2]]},
        {"op": "commit"},
        {"op": "rollback"},
    ]
    connection.close()
    connection.close()
    with pytest.raises(sqlite3.ProgrammingError, match="closed database"):
        connection.cursor().execute("select 1")


def test_cursor_fetchall_retains_order(connection_factory):
    connection, _ = connection_factory(
        [reply(), reply(result={"columns": ["x"], "rows": [[1], [2]]})]
    )
    cursor = connection.cursor().execute("select x")
    assert [row[0] for row in cursor.fetchall()] == [1, 2]
    assert list(cursor) == []


@pytest.mark.parametrize("failure", ["", "not json\n"])
def test_transport_failure_disconnects_owner(connection_factory, failure):
    class Owner:
        db_healthy = True
        _conn = object()

        def _sync_health(self, _value):
            pass

    owner = Owner()
    connection, process = connection_factory([reply(), failure], owner)
    with pytest.raises(sqlite3.OperationalError):
        connection.commit()
    assert connection._closed and owner._conn is None and owner.db_healthy is False
    assert "terminate" in process.events


def test_transport_write_error_and_dead_owner(connection_factory):
    class Owner:
        def _sync_health(self, _value):
            pass

    owner = Owner()
    connection, process = connection_factory([reply()], owner)
    del owner
    process.stdin.close()
    process.stdin = SimpleNamespace(
        write=lambda _value: (_ for _ in ()).throw(BrokenPipeError("closed")), close=lambda: None
    )
    with pytest.raises(sqlite3.OperationalError, match="closed"):
        connection.commit()
    assert connection._closed


def test_failed_open_reaps_child(monkeypatch):
    process = Process(['{"ok":false,"error_kind":"IntegrityError","error":"bad"}\n'])
    monkeypatch.setattr(go_storage.subprocess, "Popen", lambda *_args, **_kwargs: process)
    with pytest.raises(sqlite3.IntegrityError):
        go_storage.GoConnection("bad.db")
    assert process.events == ["terminate", ("wait", 5)]


def test_storage_error_reply_preserves_connection_and_syncs_health(connection_factory):
    events = []

    class Owner:
        def _sync_health(self, value):
            events.append(value)

    owner = Owner()
    failed = {"ok": False, "error_kind": "ProgrammingError", "error": "bad query"}
    connection, _ = connection_factory([reply(), json.dumps(failed) + "\n"], owner)
    with pytest.raises(sqlite3.ProgrammingError, match="bad query"):
        connection.execute("bad")
    assert events[-1] == failed and not connection._closed


def test_reap_handles_broken_close_and_timeout():
    process = Process([])
    process.stdin = SimpleNamespace(close=lambda: (_ for _ in ()).throw(BrokenPipeError()))
    waits = []

    def wait(timeout):
        waits.append(timeout)
        if len(waits) == 1:
            raise subprocess.TimeoutExpired("storage", timeout)

    process.wait = wait
    go_storage._reap(process)
    assert process.events == ["terminate", "kill"] and waits == [5, 5]
