import base64
import json
import math
import os
import sqlite3
import subprocess
import threading
import weakref
from pathlib import Path

from mining_dashboard.service.storage_service import StateManager


def _binary():
    selected = os.environ.get("PITHEAD_DASHBOARD_GO_BINARY")
    if selected:
        return selected
    return str(Path(__file__).resolve().parents[2] / "go" / "bin" / "dashboard")


def _check_text(value):
    if isinstance(value, str):
        value.encode("utf-8")
    elif isinstance(value, (list, tuple)):
        for item in value:
            _check_text(item)


def _encode(value):
    if isinstance(value, float) and not math.isfinite(value):
        return {"$float": "nan" if math.isnan(value) else ("inf" if value > 0 else "-inf")}
    if isinstance(value, bytes):
        return {"$bytes": base64.b64encode(value).decode("ascii")}
    if isinstance(value, (list, tuple)):
        return [_encode(item) for item in value]
    if isinstance(value, dict):
        return {key: _encode(item) for key, item in value.items()}
    return value


def _decode(value):
    if isinstance(value, list):
        return [_decode(item) for item in value]
    if isinstance(value, dict) and set(value) == {"$float"}:
        return {"nan": math.nan, "inf": math.inf, "-inf": -math.inf}[value["$float"]]
    if isinstance(value, dict) and set(value) == {"$bytes"}:
        return base64.b64decode(value["$bytes"])
    if isinstance(value, dict):
        return {key: _decode(item) for key, item in value.items()}
    return value


def _error(reply):
    message = reply.get("error") or "dashboard storage helper failed"
    kind = reply.get("error_kind", "")
    if kind in {"corrupt", "corruption", "database", "DatabaseError"}:
        return sqlite3.DatabaseError(message)
    if kind == "IntegrityError":
        return sqlite3.IntegrityError(message)
    if kind == "ProgrammingError":
        return sqlite3.ProgrammingError(message)
    if kind == "OverflowError":
        return OverflowError(message)
    return sqlite3.OperationalError(message)


def _reap(process):
    try:
        if process.stdin:
            process.stdin.close()
    except (BrokenPipeError, OSError):
        pass
    if process.poll() is None:
        process.terminate()
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=5)


class GoRow:
    def __init__(self, columns, values):
        self._columns = tuple(columns)
        self._values = tuple(values)
        self._index = {name: index for index, name in enumerate(self._columns)}

    def __getitem__(self, key):
        if isinstance(key, str):
            key = self._index[key]
        return self._values[key]

    def __iter__(self):
        return iter(self._values)

    def __len__(self):
        return len(self._values)

    def keys(self):
        return list(self._columns)


class GoCursor:
    def __init__(self, connection):
        self.connection = connection
        self.rowcount = -1
        self.lastrowid = None
        self.description = None
        self._rows = []
        self._index = 0

    def execute(self, sql, parameters=()):
        result = self.connection._request("execute", sql=sql, args=list(parameters)).get(
            "result", {}
        )
        columns = result.get("columns") or []
        self.description = [(name, None, None, None, None, None, None) for name in columns]
        self._rows = [GoRow(columns, _decode(values)) for values in result.get("rows") or []]
        self._index = 0
        self.rowcount = result.get("rowcount", -1)
        self.lastrowid = result.get("lastrowid")
        return self

    def executemany(self, sql, parameters):
        args = [list(values) for values in parameters]
        result = self.connection._request("executemany", sql=sql, args_list=args).get("result", {})
        self._rows = []
        self._index = 0
        self.description = None
        self.rowcount = result.get("rowcount", -1)
        self.lastrowid = result.get("lastrowid")
        return self

    def fetchone(self):
        if self._index >= len(self._rows):
            return None
        row = self._rows[self._index]
        self._index += 1
        return row

    def fetchall(self):
        rows = self._rows[self._index :]
        self._index = len(self._rows)
        return rows

    def __iter__(self):
        return self

    def __next__(self):
        row = self.fetchone()
        if row is None:
            raise StopIteration
        return row

    def close(self):
        self._rows = []


class GoConnection:
    def __init__(self, path, owner=None):
        env = os.environ.copy()
        env["PITHEAD_DASHBOARD_HELPER"] = "storage"
        self._process = subprocess.Popen(  # noqa: S603
            [_binary()],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            encoding="utf-8",
            env=env,
        )
        self._lock = threading.Lock()
        self._owner = weakref.ref(owner) if owner is not None else None
        self._closed = False
        self._finalizer = weakref.finalize(self, _reap, self._process)
        self.row_factory = GoRow
        try:
            self._request("open", path=path)
        except BaseException:
            self._closed = True
            self._finalizer()
            raise

    def _transport_failed(self):
        self._closed = True
        self._finalizer()
        if self._owner is not None:
            owner = self._owner()
            if owner is not None:
                owner.db_healthy = False
                owner._conn = None

    def _request(self, operation, **payload):
        if self._closed:
            raise sqlite3.ProgrammingError("Cannot operate on a closed database.")
        _check_text(payload.get("args", ()))
        request = {"op": operation, **_encode(payload)}
        with self._lock:
            try:
                self._process.stdin.write(json.dumps(request) + "\n")
                self._process.stdin.flush()
                line = self._process.stdout.readline()
            except (BrokenPipeError, OSError) as error:
                self._transport_failed()
                raise sqlite3.OperationalError(str(error)) from error
        if not line:
            self._transport_failed()
            raise sqlite3.OperationalError("dashboard storage helper exited")
        try:
            reply = json.loads(line)
        except json.JSONDecodeError as error:
            self._transport_failed()
            raise sqlite3.OperationalError("invalid dashboard storage response") from error
        if self._owner is not None:
            owner = self._owner()
            if owner is not None:
                owner._sync_health(reply)
        if not reply.get("ok", False):
            raise _error(reply)
        return reply

    def cursor(self):
        return GoCursor(self)

    def execute(self, sql, parameters=()):
        return self.cursor().execute(sql, parameters)

    def executemany(self, sql, parameters):
        return self.cursor().executemany(sql, parameters)

    def commit(self):
        self._request("commit")

    def rollback(self):
        self._request("rollback")

    def close(self):
        if self._closed:
            return
        try:
            self._request("close")
        finally:
            self._closed = True
            self._finalizer()

    def __enter__(self):
        return self

    def __exit__(self, error_type, error, traceback):
        if error_type is None:
            self.commit()
        else:
            self.rollback()
        return False


class GoStateManager(StateManager):
    def _open_db(self):
        self._bridge = GoConnection(self.db_path, self)
        return self._bridge

    def _request(self, operation, **payload):
        return self._bridge._request(operation, **payload)

    def _sync_health(self, reply):
        if hasattr(self, "_bridge"):
            self._conn = self._bridge if reply.get("connected") else None
        health = reply.get("health") or {}
        if not health:
            return
        self.db_healthy = bool(health.get("healthy"))
        self.db_unrecoverable = bool(health.get("unrecoverable"))
        self.db_reset_count = int(health.get("reset_count", 0))
        reset = health.get("last_reset")
        if reset:
            self.last_db_reset = {
                "ts": reset.get("time", reset.get("ts")),
                "reason": reset.get("reason"),
                "quarantine": reset.get("quarantine") or None,
            }
        else:
            self.last_db_reset = None

    def _init_db(self):
        try:
            self._request("initialize")
        except sqlite3.Error as error:
            self.logger.error("DB Init Error: %s", error)

    def _apply_schema(self):
        self._request("apply-schema")

    def _check_integrity(self):
        self._request("integrity")

    def _is_corruption_error(self, error):
        reply = self._request("classify", message=str(error))
        return bool(reply.get("result"))

    def _prune_quarantined(self):
        self._request("prune")

    def _recover_corrupt_db(self, reason):
        try:
            self._request("recover", reason=reason)
        except sqlite3.Error as error:
            self.logger.error("DB Recovery Error: %s", error)

    def _db_error(self, where, error):
        try:
            self._request("db-error", where=where, message=str(error))
        except sqlite3.Error as db_error:
            self.logger.error("%s", db_error)

    def close(self):
        with self._db_lock:
            bridge = getattr(self, "_bridge", None)
            if bridge is not None:
                try:
                    bridge.close()
                except sqlite3.Error as error:
                    self.logger.error("Error closing database: %s", error)
                finally:
                    self._bridge = None
            self._conn = None


def install():
    from mining_dashboard.service import storage_service

    storage_service.StateManager = GoStateManager
