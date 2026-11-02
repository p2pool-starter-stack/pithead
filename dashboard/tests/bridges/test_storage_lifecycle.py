import sqlite3
import threading
from types import SimpleNamespace
from unittest.mock import Mock

import pytest

from mining_dashboard import go_storage
from mining_dashboard.service import storage_service


def manager():
    value = object.__new__(go_storage.GoStateManager)
    value.logger = Mock()
    value._db_lock = threading.Lock()
    value._conn = object()
    return value


def test_state_manager_opens_owned_bridge(monkeypatch):
    value = manager()
    value.db_path = "contract.db"
    calls = []
    bridge = SimpleNamespace(_request=lambda operation, **payload: (operation, payload))

    def connect(path, owner):
        calls.append((path, owner))
        return bridge

    monkeypatch.setattr(go_storage, "GoConnection", connect)
    assert value._open_db() is bridge
    assert calls == [("contract.db", value)]
    assert value._request("classify", message="bad") == ("classify", {"message": "bad"})


def test_state_manager_health_tracks_connection_and_recovery():
    value = manager()
    value._bridge = object()
    value._sync_health({"connected": True})
    assert value._conn is value._bridge
    value._sync_health(
        {
            "connected": False,
            "health": {
                "healthy": False,
                "unrecoverable": True,
                "reset_count": 2,
                "last_reset": {"time": 10, "reason": "corrupt", "quarantine": "quarantine.db"},
            },
        }
    )
    assert value._conn is None and not value.db_healthy and value.db_unrecoverable
    assert value.db_reset_count == 2
    assert value.last_db_reset == {"ts": 10, "reason": "corrupt", "quarantine": "quarantine.db"}
    value._sync_health({"health": {"healthy": True}})
    assert value.last_db_reset is None and value.db_reset_count == 0
    del value._bridge
    value._sync_health({"health": {"last_reset": {"ts": 11, "reason": "retry"}}})
    assert value.last_db_reset == {"ts": 11, "reason": "retry", "quarantine": None}


def test_state_manager_dispatch_preserves_operation_arguments():
    value = manager()
    calls = []

    def request(operation, **payload):
        calls.append((operation, payload))
        return {"result": True}

    value._request = request
    value._init_db()
    value._apply_schema()
    value._check_integrity()
    assert value._is_corruption_error(ValueError("bad")) is True
    value._prune_quarantined()
    value._recover_corrupt_db("corrupt")
    value._db_error("write", ValueError("bad"))
    assert calls == [
        ("initialize", {}),
        ("apply-schema", {}),
        ("integrity", {}),
        ("classify", {"message": "bad"}),
        ("prune", {}),
        ("recover", {"reason": "corrupt"}),
        ("db-error", {"where": "write", "message": "bad"}),
    ]


@pytest.mark.parametrize("operation", ["_init_db", "_recover_corrupt_db", "_db_error"])
def test_state_manager_records_sqlite_errors(operation):
    value = manager()

    def request(*_args, **_payload):
        raise sqlite3.OperationalError("unavailable")

    value._request = request
    arguments = {
        "_init_db": (),
        "_recover_corrupt_db": ("corrupt",),
        "_db_error": ("write", ValueError("bad")),
    }
    getattr(value, operation)(*arguments[operation])
    assert value.logger.error.call_count == 1


@pytest.mark.parametrize("failure", [None, sqlite3.OperationalError("closed")])
def test_state_manager_close_clears_state_even_on_failure(failure):
    value = manager()
    calls = []

    def close():
        calls.append("close")
        if failure:
            raise failure

    value._bridge = SimpleNamespace(close=close)
    value.close()
    value.close()
    assert calls == ["close"] and value._conn is None and value._bridge is None
    assert value.logger.error.call_count == int(failure is not None)


def test_storage_install_restores_reference_selection(monkeypatch):
    monkeypatch.setattr(storage_service, "StateManager", storage_service.StateManager)
    go_storage.install()
    assert storage_service.StateManager is go_storage.GoStateManager
