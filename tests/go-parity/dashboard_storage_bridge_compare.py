import gc
import math
import sqlite3
import subprocess
import sys
import weakref
from pathlib import Path

import pytest

from mining_dashboard import go_storage
from mining_dashboard.service import storage_service

# ruff: noqa: S101


BINARY = Path(__file__).resolve().parents[2] / "go" / "bin" / "dashboard"


def _fake(tmp_path, body):
    path = tmp_path / "storage-helper"
    path.write_text(f"#!{sys.executable}\n" + body)
    path.chmod(0o755)
    return path


def _captured_process(monkeypatch):
    processes = []
    original = subprocess.Popen

    def start(*args, **kwargs):
        process = original(*args, **kwargs)
        processes.append(process)
        return process

    monkeypatch.setattr(go_storage.subprocess, "Popen", start)
    return processes


def test_constructor_failure_reaps_helper(tmp_path, monkeypatch):
    helper = _fake(
        tmp_path,
        "import json,sys,time\n"
        "sys.stdin.readline()\n"
        "print(json.dumps({'ok':False,'error':'open failed','error_kind':'OperationalError'}), flush=True)\n"
        "time.sleep(60)\n",
    )
    monkeypatch.setenv("PITHEAD_DASHBOARD_GO_BINARY", str(helper))
    processes = _captured_process(monkeypatch)
    with pytest.raises(sqlite3.OperationalError, match="open failed"):
        go_storage.GoConnection(":memory:")
    assert len(processes) == 1
    assert processes[0].poll() is not None


def test_early_eof_reaps_helper(tmp_path, monkeypatch):
    helper = _fake(tmp_path, "import sys\nsys.stdin.readline()\n")
    monkeypatch.setenv("PITHEAD_DASHBOARD_GO_BINARY", str(helper))
    processes = _captured_process(monkeypatch)
    with pytest.raises(sqlite3.OperationalError, match="helper exited"):
        go_storage.GoConnection(":memory:")
    assert processes[0].poll() is not None


def test_missing_helper_fails_closed(tmp_path, monkeypatch):
    monkeypatch.setenv("PITHEAD_DASHBOARD_GO_BINARY", str(tmp_path / "missing"))
    with pytest.raises(FileNotFoundError):
        go_storage.GoStateManager(":memory:")


def test_transport_values_transactions_and_errors(monkeypatch):
    monkeypatch.setenv("PITHEAD_DASHBOARD_GO_BINARY", str(BINARY))
    connection = go_storage.GoConnection(":memory:")
    try:
        connection.execute("CREATE TABLE values_test (id INTEGER PRIMARY KEY, raw BLOB, n REAL)")
        exact = 2**60 + 123
        with connection:
            connection.execute(
                "INSERT INTO values_test VALUES (?, ?, ?)", (exact, b"a\x00b", math.inf)
            )
        row = connection.execute("SELECT id, raw, n FROM values_test").fetchone()
        assert row[0] == row["id"] == exact
        assert row["raw"] == b"a\x00b"
        assert math.isinf(row["n"])
        assert connection.execute("SELECT ?", (math.nan,)).fetchone()[0] is None

        with pytest.raises(RuntimeError):
            with connection:
                connection.execute("INSERT INTO values_test VALUES (?, ?, ?)", (2, b"x", -math.inf))
                raise RuntimeError("rollback")
        assert connection.execute("SELECT COUNT(*) FROM values_test").fetchone()[0] == 1

        with pytest.raises(sqlite3.IntegrityError):
            connection.execute("INSERT INTO values_test VALUES (?, ?, ?)", (exact, b"x", 0))
        connection.rollback()
        with pytest.raises(OverflowError, match="Python int too large"):
            connection.execute("SELECT ?", (2**80,))
        with pytest.raises(sqlite3.OperationalError):
            connection.execute("SELECT * FROM missing_table")
    finally:
        connection.close()
    with pytest.raises(sqlite3.ProgrammingError):
        connection.execute("SELECT 1")


def test_unclosed_manager_reaps_helper(monkeypatch):
    monkeypatch.setenv("PITHEAD_DASHBOARD_GO_BINARY", str(BINARY))
    manager = go_storage.GoStateManager(":memory:")
    process = manager._bridge._process
    reference = weakref.ref(manager)
    del manager
    gc.collect()
    assert reference() is None
    assert process.poll() is not None


@pytest.mark.parametrize("unrecoverable", [False, True])
def test_helper_death_marks_storage_unhealthy(monkeypatch, unrecoverable):
    monkeypatch.setenv("PITHEAD_DASHBOARD_GO_BINARY", str(BINARY))
    manager = go_storage.GoStateManager(":memory:")
    try:
        process = manager._bridge._process
        manager.db_unrecoverable = unrecoverable
        process.terminate()
        process.wait(timeout=5)
        manager.update_history(100, p2pool_hr=100)
        assert manager.is_db_healthy() is False
        assert manager.is_db_unrecoverable() is unrecoverable
        assert manager._conn is None
        assert process.poll() is not None
    finally:
        manager.close()


def test_failed_recovery_detaches_and_retry_reattaches(monkeypatch):
    monkeypatch.setenv("PITHEAD_DASHBOARD_GO_BINARY", str(BINARY))
    manager = go_storage.GoStateManager(":memory:")
    try:
        guard = storage_service.sqlite3.connect

        def fail(*args, **kwargs):
            del args, kwargs
            raise sqlite3.OperationalError("unable to open database file")

        monkeypatch.setattr(storage_service.sqlite3, "connect", fail)
        manager._recover_corrupt_db("forced open failure")
        assert manager._conn is None
        assert manager._bridge is not None
        assert manager.is_db_unrecoverable() is True

        monkeypatch.setattr(storage_service.sqlite3, "connect", guard)
        manager._recover_corrupt_db("retry")
        assert manager._conn is manager._bridge
        assert manager.is_db_unrecoverable() is False
        assert manager.is_db_healthy() is True
    finally:
        manager.close()


def test_failed_recovery_explicit_close_reaps_bridge(monkeypatch):
    monkeypatch.setenv("PITHEAD_DASHBOARD_GO_BINARY", str(BINARY))
    manager = go_storage.GoStateManager(":memory:")
    process = manager._bridge._process

    def fail(*args, **kwargs):
        del args, kwargs
        raise sqlite3.OperationalError("unable to open database file")

    monkeypatch.setattr(storage_service.sqlite3, "connect", fail)
    manager._recover_corrupt_db("forced open failure")
    assert manager._conn is None
    assert process.poll() is None
    manager.close()
    assert manager._bridge is None
    assert process.poll() is not None


def test_error_mapping_is_exact():
    cases = (
        ("DatabaseError", sqlite3.DatabaseError),
        ("IntegrityError", sqlite3.IntegrityError),
        ("OperationalError", sqlite3.OperationalError),
        ("ProgrammingError", sqlite3.ProgrammingError),
        ("OverflowError", OverflowError),
    )
    for kind, expected in cases:
        assert isinstance(go_storage._error({"error": "x", "error_kind": kind}), expected)
