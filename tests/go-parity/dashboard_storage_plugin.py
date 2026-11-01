import os
import sqlite3
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
BINARY = REPO_ROOT / "go" / "bin" / "dashboard"
_ORIGINAL_REQUEST = None
_SQLITE_GUARD = None


class _SQLiteGuard:
    Error = sqlite3.Error
    DatabaseError = sqlite3.DatabaseError
    OperationalError = sqlite3.OperationalError
    ProgrammingError = sqlite3.ProgrammingError
    Row = sqlite3.Row

    def __getattr__(self, name):
        return getattr(sqlite3, name)

    def connect(self, *args, **kwargs):
        del args, kwargs
        raise AssertionError("Python SQLite connection used in Go storage mode")


def _fatal(*args, **kwargs):
    del args, kwargs
    raise AssertionError("Python storage lifecycle used in Go storage mode")


def _adapter_request(self, operation, **payload):
    if operation == "recover":
        apply_schema = self.__dict__.get("_apply_schema")
        if apply_schema is not None:
            try:
                apply_schema()
            except sqlite3.Error as error:
                payload["schema_error"] = str(error)
        from mining_dashboard.service import storage_service

        connect = storage_service.sqlite3.connect
        if getattr(connect, "__self__", None) is not _SQLITE_GUARD:
            try:
                connect(self.db_path, timeout=30.0, check_same_thread=False)
            except sqlite3.Error as error:
                payload["open_error"] = str(error)
    return _ORIGINAL_REQUEST(self, operation, **payload)


def pytest_configure(config):
    del config
    if os.environ.get("PITHEAD_IMPL") != "go":
        return
    os.environ["PITHEAD_DASHBOARD_GO_BINARY"] = str(BINARY)

    from mining_dashboard import go_storage
    from mining_dashboard.service import storage_schema, storage_service
    from mining_dashboard.service.workers import worker_config_store

    global _ORIGINAL_REQUEST, _SQLITE_GUARD
    original = storage_service.StateManager
    _ORIGINAL_REQUEST = go_storage.GoStateManager._request
    go_storage.GoStateManager._request = _adapter_request

    guard = _SQLiteGuard()
    _SQLITE_GUARD = guard
    storage_service.sqlite3 = guard
    for name in (
        "_init_db",
        "_apply_schema",
        "_check_integrity",
        "_is_corruption_error",
        "_prune_quarantined",
        "_create_tables",
        "_migrate_db",
        "_create_indexes",
    ):
        setattr(storage_schema.StorageSchemaMixin, name, _fatal)
    worker_config_store.WorkerConfigStoreMixin._migrate_worker_config_revision = _fatal
    storage_service.StateManager._recover_corrupt_db = _fatal
    storage_service.StateManager._db_error = _fatal
    storage_service.StateManager = go_storage.GoStateManager

    for module in tuple(sys.modules.values()):
        if module is not None and getattr(module, "StateManager", None) is original:
            module.StateManager = go_storage.GoStateManager
